/* Preliminary display/graphics checks, not proof of app context support. */
#include <EGL/egl.h>
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <string.h>
#include <wayland-client.h>

static int probe_x11(int graphics)
{
    Display *display = XOpenDisplay(NULL);
    if (!display)
        return 2;
    if (!graphics) {
        XCloseDisplay(display);
        return 0;
    }

    int event = 0, error = 0;
    if (!glXQueryExtension(display, &event, &error)) {
        XCloseDisplay(display);
        return 3;
    }

    int count = 0;
    GLXFBConfig *configs = glXGetFBConfigs(display, DefaultScreen(display), &count);
    int available = configs != NULL && count > 0;
    if (configs)
        XFree(configs);
    XCloseDisplay(display);
    return available ? 0 : 4;
}

static int probe_egl(void)
{
    struct wl_display *wayland = wl_display_connect(NULL);
    if (!wayland)
        return 2;

    EGLDisplay display = eglGetDisplay((EGLNativeDisplayType)wayland);
    if (display == EGL_NO_DISPLAY) {
        wl_display_disconnect(wayland);
        return 3;
    }
    if (!eglInitialize(display, NULL, NULL)) {
        wl_display_disconnect(wayland);
        return 4;
    }

    const char *vendor = eglQueryString(display, EGL_VENDOR);
    if (vendor)
        fprintf(stderr, "EGL vendor: %s\n", vendor);
    eglTerminate(display);
    wl_display_disconnect(wayland);
    return 0;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "glx";
    int status = strcmp(mode, "egl") == 0
        ? probe_egl()
        : probe_x11(strcmp(mode, "x11") != 0);
    fprintf(stderr, "probe(%s) rc=%d\n", mode, status);
    return status;
}
