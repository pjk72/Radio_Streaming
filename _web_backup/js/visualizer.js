class AudioVisualizer {
    constructor(canvasId) {
        this.canvas = document.getElementById(canvasId);
        this.ctx = this.canvas.getContext('2d');
        this.audioContext = null;
        this.analyser = null;
        this.dataArray = null;
        this.source = null;
        this.animationId = null;

        this.resize();
        window.addEventListener('resize', () => this.resize());
    }

    resize() {
        this.canvas.width = this.canvas.parentElement.offsetWidth;
        this.canvas.height = this.canvas.parentElement.offsetHeight;
    }

    setup(audioElement) {
        if (!this.audioContext) {
            this.audioContext = new (window.AudioContext || window.webkitAudioContext)();
            this.analyser = this.audioContext.createAnalyser();
            this.analyser.fftSize = 256;

            this.source = this.audioContext.createMediaElementSource(audioElement);
            this.source.connect(this.analyser);
            this.analyser.connect(this.audioContext.destination);

            const bufferLength = this.analyser.frequencyBinCount;
            this.dataArray = new Uint8Array(bufferLength);
        }
    }

    start() {
        if (this.audioContext && this.audioContext.state === 'suspended') {
            this.audioContext.resume();
        }
        this.draw();
    }

    draw() {
        this.animationId = requestAnimationFrame(() => this.draw());

        this.analyser.getByteFrequencyData(this.dataArray);

        this.ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);

        const bufferLength = this.dataArray.length;
        // Use a subset of data for better visuals (low frequencies are usually more active)
        const usefulData = this.dataArray.slice(0, bufferLength * 0.7);
        const barWidth = (this.canvas.width / usefulData.length);

        let x = 0;

        for (let i = 0; i < usefulData.length; i++) {
            const barHeight = (usefulData[i] / 255) * this.canvas.height * 0.8;

            // Premium gradient color with opacity based on height
            const gradient = this.ctx.createLinearGradient(0, this.canvas.height, 0, 0);
            gradient.addColorStop(0, '#6c5ce7'); // Primary purple
            gradient.addColorStop(0.5, '#00cec9'); // Teal
            gradient.addColorStop(1, '#a29bfe'); // Light purple top

            this.ctx.fillStyle = gradient;

            // Draw rounded bars
            this.roundRect(x, this.canvas.height - barHeight, barWidth - 2, barHeight, 4);

            x += barWidth;
        }
    }

    roundRect(x, y, w, h, radius) {
        if (w < 2 * radius) radius = w / 2;
        if (h < 2 * radius) radius = h / 2;
        this.ctx.beginPath();
        this.ctx.moveTo(x + radius, y);
        this.ctx.arcTo(x + w, y, x + w, y + h, radius);
        this.ctx.arcTo(x + w, y + h, x, y + h, radius);
        this.ctx.arcTo(x, y + h, x, y, radius);
        this.ctx.arcTo(x, y, x + w, y, radius);
        this.ctx.closePath();
        this.ctx.fill();
    }
}
