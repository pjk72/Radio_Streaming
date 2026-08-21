class UpgradeProposal {
  final String playlistId;
  final String playlistName;
  final String songId;
  final String songTitle;
  final String songArtist;
  final String songAlbum;
  final String localPath;
  final int localId;

  UpgradeProposal({
    required this.playlistId,
    this.playlistName = '',
    required this.songId,
    required this.songTitle,
    required this.songArtist,
    required this.songAlbum,
    required this.localPath,
    required this.localId,
  });
}
