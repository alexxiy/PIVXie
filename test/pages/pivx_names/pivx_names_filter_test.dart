import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/pivx_name/pivx_names_registrar.dart';

void main() {
  test("orders, as the registrar names them", () {
    String spelled(PivxNamesSort s, {required bool my}) =>
        "${s.key(my: my)} ${s.order}";
    expect(
      [for (final s in PivxNamesSort.values) spelled(s, my: true)],
      [
        "name asc",
        "name desc",
        "price asc",
        "price desc",
        "updated desc",
        "updated asc",
      ],
    );
    expect(
      [for (final s in PivxNamesSort.values) spelled(s, my: false)],
      [
        "name asc",
        "name desc",
        "price asc",
        "price desc",
        "listed desc",
        "listed asc",
      ],
    );
  });

  test("statuses, as the registrar names them", () {
    expect(
      [for (final s in PivxNamesStatusFilter.values) s.key],
      ["all", "listed", "not_listed"],
    );
    expect(kPivxNamesNoFilter, (
      status: PivxNamesStatusFilter.all,
      zone: null,
      sort: PivxNamesSort.nameAsc,
    ));
  });
}
