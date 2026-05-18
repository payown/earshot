enum EpisodeAction {
  playNow,
  addToQueue,
  markPlayed,
  openShowNotes,
  download,
  share
  ;

  String get label => switch (this) {
    EpisodeAction.playNow => 'Play now',
    EpisodeAction.addToQueue => 'Add to queue',
    EpisodeAction.markPlayed => 'Mark as played',
    EpisodeAction.openShowNotes => 'Open show notes',
    EpisodeAction.download => 'Download',
    EpisodeAction.share => 'Share',
  };

  String get key => name;
}

enum PodcastAction {
  open,
  toggleNotifications,
  toggleAutoQueue,
  unsubscribe,
  share
  ;

  String get label => switch (this) {
    PodcastAction.open => 'Open podcast',
    PodcastAction.toggleNotifications => 'Toggle notifications',
    PodcastAction.toggleAutoQueue => 'Toggle auto-queue',
    PodcastAction.unsubscribe => 'Unsubscribe',
    PodcastAction.share => 'Share podcast',
  };

  String get key => name;
}

const defaultEpisodeActions = [
  EpisodeAction.playNow,
  EpisodeAction.addToQueue,
  EpisodeAction.markPlayed,
  EpisodeAction.openShowNotes,
  EpisodeAction.download,
  EpisodeAction.share,
];

const defaultPodcastActions = [
  PodcastAction.open,
  PodcastAction.toggleNotifications,
  PodcastAction.toggleAutoQueue,
  PodcastAction.unsubscribe,
  PodcastAction.share,
];
