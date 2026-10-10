import '../app_config.dart';

abstract class GitStatus {
  static String get appCommitHash => AppConfig.commitHash;
}
