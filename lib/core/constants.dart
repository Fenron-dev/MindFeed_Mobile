abstract class AppRoutes {
  static const feed = '/';
  static const search = '/search';
  static const settings = '/settings';
  static const entryDetail = '/entry/:id';
  static const capture = '/capture';
  static const containerDetail = '/container/:id';
  static const vaultSetup = '/vault-setup';

  static String entryDetailPath(String id) => '/entry/$id';
  static String containerDetailPath(String id) => '/container/$id';
}

abstract class AppStrings {
  static const appName = 'MindFeed';
  static const vaultDbName = 'mindfeed.db';
  static const attachmentsDirName = 'attachments';
  static const backupDirName = 'backups';
}
