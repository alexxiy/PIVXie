#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include <cstring>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// The app icon in the bundle (data/icon.png), or null.
static gchar* bundled_icon_path() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return nullptr;
  g_autofree gchar* dir = g_path_get_dirname(exe);
  gchar* icon = g_build_filename(dir, "data", "icon.png", nullptr);
  if (!g_file_test(icon, G_FILE_TEST_IS_REGULAR)) {
    g_free(icon);
    return nullptr;
  }
  return icon;
}

// Writes [contents] to [path] unless it already holds them.
static void write_if_changed(const gchar* path, const gchar* contents,
                             gsize length) {
  g_autofree gchar* old = nullptr;
  gsize old_length = 0;
  if (g_file_get_contents(path, &old, &old_length, nullptr) &&
      old_length == length && memcmp(old, contents, length) == 0) {
    return;
  }
  g_autofree gchar* dir = g_path_get_dirname(path);
  g_mkdir_with_parents(dir, 0755);
  g_autoptr(GError) error = nullptr;
  if (!g_file_set_contents(path, contents, length, &error)) {
    g_warning("Can't write %s: %s", path, error->message);
  }
}

// Wayland desktops show a window's icon from the .desktop file named
// after its app ID, so without one (an unpacked tarball) the taskbar shows
// a generic icon. Add one for this bundle to the user's applications,
// unless an install (system, Flatpak) or the user already has one.
static void ensure_desktop_entry() {
  if (g_getenv("FLATPAK_ID") != nullptr || g_getenv("SNAP") != nullptr) {
    return;
  }
  g_autofree gchar* bundled_icon = bundled_icon_path();
  if (bundled_icon == nullptr) return;
  // An AppImage runs from a new mount each time: point at the image.
  const gchar* appimage = g_getenv("APPIMAGE");
  g_autofree gchar* exe =
      appimage != nullptr ? g_strdup(appimage)
                          : g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) return;

  const gchar* file_name = APPLICATION_ID ".desktop";
  for (const gchar* const* dir = g_get_system_data_dirs(); *dir != nullptr;
       dir++) {
    g_autofree gchar* other =
        g_build_filename(*dir, "applications", file_name, nullptr);
    if (g_file_test(other, G_FILE_TEST_EXISTS)) return;
  }
  g_autofree gchar* path = g_build_filename(
      g_get_user_data_dir(), "applications", file_name, nullptr);
  const gchar* group = G_KEY_FILE_DESKTOP_GROUP;
  const gchar* ours = "X-Added-By-App";
  g_autoptr(GKeyFile) existing = g_key_file_new();
  if (g_key_file_load_from_file(existing, path, G_KEY_FILE_NONE, nullptr) &&
      !g_key_file_get_boolean(existing, group, ours, nullptr)) {
    return;
  }

  // A copy of the icon, so the entry keeps it while the bundle moves.
  g_autofree gchar* icon = g_build_filename(
      g_get_user_data_dir(), "icons", APPLICATION_ID ".png", nullptr);
  g_autofree gchar* icon_data = nullptr;
  gsize icon_length = 0;
  if (!g_file_get_contents(bundled_icon, &icon_data, &icon_length, nullptr)) {
    return;
  }
  write_if_changed(icon, icon_data, icon_length);

  // Exec quoting (Desktop Entry spec): double quotes, with " ` $ \ escaped.
  GString* exec = g_string_new("\"");
  for (const gchar* c = exe; *c != '\0'; c++) {
    if (strchr("\"`$\\", *c) != nullptr) g_string_append_c(exec, '\\');
    g_string_append_c(exec, *c);
  }
  g_string_append_c(exec, '"');
  g_autofree gchar* exec_line = g_string_free(exec, FALSE);

  g_autoptr(GKeyFile) entry = g_key_file_new();
  g_key_file_set_string(entry, group, "Type", "Application");
  g_key_file_set_string(entry, group, "Name", "PlaceHolderName");
  g_key_file_set_string(entry, group, "Exec", exec_line);
  g_key_file_set_string(entry, group, "Icon", icon);
  g_key_file_set_boolean(entry, group, "Terminal", FALSE);
  g_key_file_set_string(entry, group, "Categories", "Office;Finance;");
  g_key_file_set_string(entry, group, "StartupWMClass", APPLICATION_ID);
  g_key_file_set_boolean(entry, group, ours, TRUE);
  gsize length = 0;
  g_autofree gchar* data = g_key_file_to_data(entry, &length, nullptr);
  write_if_changed(path, data, length);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView *view)
{
    gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Started again (e.g. to open a pivx: link): show the window we have.
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a traditional title bar by default for best compatibility across
  // desktop environments (KDE, XFCE, tiling WMs, etc.).
  // Set GTK_CSD=1 to use a GNOME-style header bar instead.
  const char* gtk_csd_env_var = getenv("GTK_CSD");
  if (gtk_csd_env_var && strcmp(gtk_csd_env_var, "1") == 0) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "PlaceHolderName");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "PlaceHolderName");
  }

  g_autofree gchar* icon = bundled_icon_path();
  if (icon != nullptr) gtk_window_set_icon_from_file(window, icon, nullptr);

  gtk_window_set_default_size(window, 1220, 500);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);
  // Skia, not Impeller: Impeller's OpenGL renderer draws filled shapes
  // without anti-aliasing on many Linux setups, so the SVG logos and icons
  // came out jagged.
  fl_dart_project_set_enable_impeller(project, FALSE);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000 for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb), self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  // One instance, which gets the pivx: links of later starts, unless it
  // is started on another data directory ("-d <dir>").
  for (gchar** arg = *arguments + 1; *arg != nullptr; arg++) {
    if (g_strcmp0(*arg, "-d") == 0) {
      g_application_set_flags(
          application,
          static_cast<GApplicationFlags>(g_application_get_flags(application) |
                                         G_APPLICATION_NON_UNIQUE));
      break;
    }
  }

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  // Not handled here: the command line goes on to the first instance,
  // where the app_links plugin reads the link from it.
  return FALSE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.
  ensure_desktop_entry();

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_HANDLES_COMMAND_LINE,
                                     nullptr));
}
