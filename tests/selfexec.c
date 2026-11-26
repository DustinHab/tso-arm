// A program that starts itself again through /proc/self/exe, as Chromium starts its zygote, renderers and services,
// and says what /proc/self/exe names each time. Under tso-arm a program inside the root file system (where
// 'tso-arm app' installs programs) got ENOEXEC for that execve: glibc's execvp then ran the program as a shell script
// ("/proc/self/exe: 1: Syntax error").
//   selfexec          prints two lines; exit status 1 if the second start did not happen
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char** argv) {
    char exe[4096];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    exe[n > 0 ? n : 0] = 0;
    if (argc > 1 && !strcmp(argv[1], "again")) {
        printf("selfexec: started again, /proc/self/exe is %s\n", exe);
        return 0;
    }
    printf("selfexec: /proc/self/exe is %s\n", exe);
    fflush(stdout);
    char* args[] = {argv[0], "again", NULL};
    execv("/proc/self/exe", args);
    printf("selfexec: execv /proc/self/exe failed: %s\n", strerror(errno));
    return 1;
}
