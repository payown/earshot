enum EpisodeAction {
  playNow,
  playNext,
  addToEndOfQueue,
  markPlayed,
  openShowNotes,
  bookmark,
  download,
  share;

  String get label => switch (this) {
    EpisodeAction.playNow => 'Play now',
    EpisodeAction.playNext => 'Play next',
    EpisodeAction.addToEndOfQueue => 'Add to end of queue',
    EpisodeAction.markPlayed => 'Mark as played',
    EpisodeAction.openShowNotes => 'Open show notes',
    EpisodeAction.bookmark => 'Bookmark current spot',
    EpisodeAction.download => 'Download',
    EpisodeAction.share => 'Share',
  };

  String get key => name;
}

enum PodcastAction {
  open,
  toggleNotifications,
  toggleAutoQueue,
  toggleInboxExcluded,
  unsubscribe,
  share,
  manageFolders;

  String get label => switch (this) {
    PodcastAction.open => 'Open podcast',
    PodcastAction.toggleNotifications => 'Toggle notifications',
    PodcastAction.toggleAutoQueue => 'Toggle auto-queue',
    PodcastAction.toggleInboxExcluded => 'Toggle inbox',
    PodcastAction.unsubscribe => 'Unfollow',
    PodcastAction.share => 'Share podcast',
    PodcastAction.manageFolders => 'Manage folders',
  };

  String get key => name;
}

const defaultEpisodeActions = [
  EpisodeAction.playNow,
  EpisodeAction.playNext,
  EpisodeAction.addToEndOfQueue,
  EpisodeAction.markPlayed,
  EpisodeAction.openShowNotes,
  EpisodeAction.bookmark,
  EpisodeAction.download,
  EpisodeAction.share,
];

const defaultPodcastActions = [
  PodcastAction.open,
  PodcastAction.toggleNotifications,
  PodcastAction.toggleAutoQueue,
  PodcastAction.toggleInboxExcluded,
  PodcastAction.unsubscribe,
  PodcastAction.share,
  PodcastAction.manageFolders,
];
