// Whether a program with one thread of its own sees one thread in /proc/self/task, as Chromium's zygote checks before
// it forks (sandbox::ThreadHelpers::IsSingleThreaded: the directory's link count is 3, "." and ".." and one task).
// Under FEX a thread of FEX's own counts as well: the writer of its disk cache made Steam's steamwebhelper (Chromium)
// stop at "CHECK(sandbox::ThreadHelpers::IsSingleThreaded())" in every zygote.
//   singlethread          prints the tasks it sees; exit status 1 with more than one
#include <stdio.h>
#include <sys/stat.h>

int main(void) {
    struct stat st;
    if (stat("/proc/self/task/", &st) != 0) {
        perror("/proc/self/task");
        return 2;
    }
    long tasks = (long)st.st_nlink - 2;
    printf("singlethread: %ld task%s in /proc/self/task\n", tasks, tasks == 1 ? "" : "s");
    return tasks == 1 ? 0 : 1;
}
