package com.fazio.musicstream

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.util.Log
import java.io.File

object AudioTranscoder {
    private const val TAG = "AudioTranscoder"

    /**
     * Hardware-accelerated transcode using Android native MediaCodec + MediaMuxer.
     * Decodes any audio (Opus, WebM, FLAC, Vorbis, AAC, etc.) using hardware decoder
     * and encodes to standard AAC-LC / MP4 container using hardware encoder in ~200-400ms.
     */
    fun transcodeToAudio(
        context: Context,
        inputPath: String,
        outputPath: String,
        bitrateKbps: Int = 192
    ): Boolean {
        val inputFile = File(inputPath)
        val outputFile = File(outputPath)

        if (!inputFile.exists() || inputFile.length() == 0L) {
            Log.e(TAG, "Input file does not exist or is empty: $inputPath")
            return false
        }

        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null

        try {
            extractor.setDataSource(inputFile.absolutePath)
            var audioTrackIndex = -1
            var inputFormat: MediaFormat? = null

            for (i in 0 until extractor.trackCount) {
                val trackFormat = extractor.getTrackFormat(i)
                val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: ""
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    inputFormat = trackFormat
                    break
                }
            }

            if (audioTrackIndex < 0 || inputFormat == null) {
                Log.e(TAG, "No audio track found in: $inputPath")
                return false
            }

            extractor.selectTrack(audioTrackIndex)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME)!!
            val sampleRate = if (inputFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            } else 44100
            val channelCount = if (inputFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            } else 2

            // 1. Hardware Decoder
            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(inputFormat, null, null, 0)
            decoder.start()

            // 2. Hardware AAC Encoder
            val outputMime = MediaFormat.MIMETYPE_AUDIO_AAC
            val encoderFormat = MediaFormat.createAudioFormat(outputMime, sampleRate, channelCount).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 64 * 1024)
            }

            encoder = MediaCodec.createEncoderByType(outputMime)
            encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()

            val tempOutputFile = File("${outputFile.absolutePath}.tmp")
            if (tempOutputFile.exists()) tempOutputFile.delete()
            tempOutputFile.parentFile?.mkdirs()

            muxer = MediaMuxer(tempOutputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            var muxerAudioTrack = -1
            var isMuxerStarted = false

            val decBufferInfo = MediaCodec.BufferInfo()
            val encBufferInfo = MediaCodec.BufferInfo()
            var isExtractorEOS = false
            var isDecoderEOS = false
            var isEncoderEOS = false
            val timeoutUs = 500L

            while (!isEncoderEOS) {
                // A. Feed extractor samples into decoder
                if (!isExtractorEOS) {
                    val inIndex = decoder.dequeueInputBuffer(timeoutUs)
                    if (inIndex >= 0) {
                        val inputBuffer = decoder.getInputBuffer(inIndex)!!
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            decoder.queueInputBuffer(inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            isExtractorEOS = true
                        } else {
                            val pts = extractor.sampleTime
                            decoder.queueInputBuffer(inIndex, 0, sampleSize, pts, 0)
                            extractor.advance()
                        }
                    }
                }

                // B. Drain decoder output and feed PCM into encoder
                if (!isDecoderEOS) {
                    var outIndex = decoder.dequeueOutputBuffer(decBufferInfo, timeoutUs)
                    while (outIndex >= 0) {
                        val decodedBuffer = decoder.getOutputBuffer(outIndex)!!
                        val isEOS = (decBufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0

                        if (decBufferInfo.size > 0 || isEOS) {
                            var encInIndex = encoder.dequeueInputBuffer(timeoutUs)
                            while (encInIndex < 0 && !isEncoderEOS) {
                                // Drain encoder if input buffer is not immediately available
                                drainEncoderToMuxer(encoder, muxer, encBufferInfo, isMuxerStarted, muxerAudioTrack) { track, started ->
                                    muxerAudioTrack = track
                                    isMuxerStarted = started
                                }
                                if ((encBufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                    isEncoderEOS = true
                                    break
                                }
                                encInIndex = encoder.dequeueInputBuffer(timeoutUs)
                            }

                            if (encInIndex >= 0) {
                                val encInBuf = encoder.getInputBuffer(encInIndex)!!
                                if (decBufferInfo.size > 0) {
                                    decodedBuffer.position(decBufferInfo.offset)
                                    decodedBuffer.limit(decBufferInfo.offset + decBufferInfo.size)
                                    encInBuf.put(decodedBuffer)
                                }
                                val flags = if (isEOS) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
                                encoder.queueInputBuffer(encInIndex, 0, decBufferInfo.size, decBufferInfo.presentationTimeUs, flags)
                            }
                        }

                        decoder.releaseOutputBuffer(outIndex, false)
                        if (isEOS) {
                            isDecoderEOS = true
                            break
                        }
                        outIndex = decoder.dequeueOutputBuffer(decBufferInfo, 0L)
                    }
                }

                // C. Drain encoder output to MediaMuxer
                drainEncoderToMuxer(encoder, muxer, encBufferInfo, isMuxerStarted, muxerAudioTrack) { track, started ->
                    muxerAudioTrack = track
                    isMuxerStarted = started
                }
                if ((encBufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    isEncoderEOS = true
                }
            }

            try {
                if (isMuxerStarted) {
                    muxer.stop()
                }
            } catch (_: Exception) {}

            if (tempOutputFile.exists() && tempOutputFile.length() > 1024) {
                if (outputFile.exists()) outputFile.delete()
                tempOutputFile.renameTo(outputFile)
                MediaScannerConnection.scanFile(context, arrayOf(outputFile.absolutePath), arrayOf("audio/mp4")) { _, _ -> }
                Log.i(TAG, "Hardware transcode successful: ${outputFile.absolutePath} (${outputFile.length()} bytes)")
                return true
            }
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Hardware transcode failed: ${e.message}", e)
            return false
        } finally {
            try { decoder?.stop() } catch (_: Exception) {}
            try { decoder?.release() } catch (_: Exception) {}
            try { encoder?.stop() } catch (_: Exception) {}
            try { encoder?.release() } catch (_: Exception) {}
            try { muxer?.release() } catch (_: Exception) {}
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    private inline fun drainEncoderToMuxer(
        encoder: MediaCodec,
        muxer: MediaMuxer,
        bufferInfo: MediaCodec.BufferInfo,
        isMuxerStarted: Boolean,
        muxerAudioTrack: Int,
        onMuxerTrack: (Int, Boolean) -> Unit
    ) {
        var currentTrack = muxerAudioTrack
        var started = isMuxerStarted

        var outIndex = encoder.dequeueOutputBuffer(bufferInfo, 0L)
        while (outIndex >= 0) {
            if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val newFormat = encoder.outputFormat
                currentTrack = muxer.addTrack(newFormat)
                muxer.start()
                started = true
                onMuxerTrack(currentTrack, started)
            } else if (outIndex >= 0) {
                val encodedBuf = encoder.getOutputBuffer(outIndex)!!
                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                    bufferInfo.size = 0
                }
                if (bufferInfo.size > 0 && started && currentTrack >= 0) {
                    encodedBuf.position(bufferInfo.offset)
                    encodedBuf.limit(bufferInfo.offset + bufferInfo.size)
                    muxer.writeSampleData(currentTrack, encodedBuf, bufferInfo)
                }
                encoder.releaseOutputBuffer(outIndex, false)
            }
            outIndex = encoder.dequeueOutputBuffer(bufferInfo, 0L)
        }
    }
}
