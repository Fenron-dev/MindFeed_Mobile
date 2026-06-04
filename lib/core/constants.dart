abstract class AppRoutes {
  static const feed = '/';
  static const search = '/search';
  static const settings = '/settings';
  static const entryDetail = '/entry/:id';
  static const capture = '/capture';
  static const containerDetail = '/container/:id';
  static const containerNew = '/container-new';
  static const containerEdit = '/container-edit/:id';
  static const vaultSetup = '/vault-setup';
  static const vaultSwitcher = '/vault-switcher';

  static String entryDetailPath(String id) => '/entry/$id';
  static String containerDetailPath(String id) => '/container/$id';
  static String containerEditPath(String id) => '/container-edit/$id';
}

abstract class AppStrings {
  static const appName = 'MindFeed';
  static const vaultDbName = 'mindfeed.db';
  static const attachmentsDirName = 'attachments';
  static const backupDirName = 'backups';
}
