// Nova's own program. It is deliberately tiny and never changes between versions, because
// macOS ties the permissions a person has granted (microphone, speech, Accessibility) to
// this exact program. Everything that does change, the window, the engine and their helper
// files, is the "payload". It is kept in Nova's folder in the user's Library, so an update
// replaces the payload and leaves this program, and the permissions, alone.
//
// At launch: if there is no payload in the Library yet, or the one inside the app is newer
// (the person installed a newer Nova by hand), the app's copy is put there. Then the window's
// code is loaded from the payload and started.
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *files[] = { "libNovaUI.dylib", "nova-engine", "kokoro_server.py", "jarvis_voice_server.py", "talking_piano_bridge.lua", "version.txt", NULL };

static void make_dirs(const char *path) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; }
    mkdir(tmp, 0755);
}

// "1.10.2" as three numbers; a missing or unreadable file is version 0.0.0.
static void version_of(const char *dir, int v[3]) {
    char path[PATH_MAX];
    v[0] = v[1] = v[2] = 0;
    snprintf(path, sizeof path, "%s/version.txt", dir);
    FILE *f = fopen(path, "r");
    if (!f) return;
    if (fscanf(f, "%d.%d.%d", &v[0], &v[1], &v[2]) < 1) v[0] = v[1] = v[2] = 0;
    fclose(f);
}

static int copy_file(const char *from, const char *to, int executable) {
    FILE *in = fopen(from, "rb");
    if (!in) return 0;
    char part[PATH_MAX];
    snprintf(part, sizeof part, "%s.part", to);
    FILE *out = fopen(part, "wb");
    if (!out) { fclose(in); return 0; }
    char buf[65536];
    size_t n;
    int ok = 1;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) if (fwrite(buf, 1, n, out) != n) { ok = 0; break; }
    fclose(in);
    if (fclose(out) != 0) ok = 0;
    if (ok) { chmod(part, executable ? 0755 : 0644); ok = rename(part, to) == 0; }
    if (!ok) unlink(part);
    return ok;
}

static int start_from(const char *dir) {
    char lib[PATH_MAX];
    snprintf(lib, sizeof lib, "%s/libNovaUI.dylib", dir);
    if (access(lib, R_OK) != 0) return 0;
    setenv("NOVA_PAYLOAD", dir, 1);
    void *handle = dlopen(lib, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) { fprintf(stderr, "Nova could not load %s: %s\n", lib, dlerror()); return 0; }
    void (*start)(void) = (void (*)(void))dlsym(handle, "tp_main");
    if (!start) return 0;
    start();
    return 1;
}

int main(int argc, char **argv) {
    char exe[PATH_MAX], real[PATH_MAX], inside[PATH_MAX], data[PATH_MAX], outside[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0 || !realpath(exe, real)) snprintf(real, sizeof real, "%s", argv[0]);
    char *slash = strrchr(real, '/');
    if (slash) *slash = 0;
    snprintf(inside, sizeof inside, "%s/../Resources/payload", real);

    const char *home = getenv("NOVA_HOME");
    if (home && *home) snprintf(data, sizeof data, "%s", home);
    else snprintf(data, sizeof data, "%s/Library/Application Support/Nova", getenv("HOME") ? getenv("HOME") : "/tmp");
    snprintf(outside, sizeof outside, "%s/app", data);

    int a[3], b[3];
    version_of(inside, a);
    version_of(outside, b);
    int app_is_newer = a[0] != b[0] ? a[0] > b[0] : a[1] != b[1] ? a[1] > b[1] : a[2] > b[2];
    if (app_is_newer) {
        make_dirs(outside);
        int ok = 1;
        // The version file goes last: it is what says the copy is complete.
        for (int i = 0; files[i] && ok; i++) {
            char from[PATH_MAX], to[PATH_MAX];
            snprintf(from, sizeof from, "%s/%s", inside, files[i]);
            snprintf(to, sizeof to, "%s/%s", outside, files[i]);
            ok = copy_file(from, to, strcmp(files[i], "nova-engine") == 0);
        }
        if (!ok) fprintf(stderr, "Nova could not set up its files in %s; running from inside the app instead.\n", outside);
    }
    if (start_from(outside)) return 0;
    if (start_from(inside)) return 0;       // the Library could not be written to: run straight from the app
    fprintf(stderr, "Nova could not start: its files are missing. Downloading it again should fix this.\n");
    return 1;
}
