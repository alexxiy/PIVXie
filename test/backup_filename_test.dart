import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/pages/settings_views/global_settings_view/stack_backup_views/helpers/restore_create_backup.dart';

void main() {
  final date = DateTime(2026, 10, 2, 9, 5, 3);

  test("backup file names start with the app name", () {
    expect(
      createBackupFilename("/dir", date),
      "/dir/PIVXie-backup-2026-10-02_09-05-03.swb",
    );
    expect(
      createAutoBackupFilename("/dir", date),
      "/dir/PIVXie-autobackup-2026-10-02_09-05-03.swb",
    );
  });

  test("auto backup date is read back from the file name", () {
    final name = createAutoBackupFilename("/dir", date).split("/").last;
    expect(autoBackupDate(name), date);
    expect(autoBackupDate("PIVXie-backup-2026-10-02_09-05-03.swb"), isNull);
    expect(autoBackupDate("notes.txt"), isNull);
  });
}
