#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <errno.h>
#include <unistd.h>

// TODO: Add signal processing.

int main(int argc, char *argv[]) {
    int status;
    pid_t pid;

    for (;;) {
        pid = waitpid(-1, &status, 0);

        if (pid == -1) {
            if (errno == EINTR) {
                continue;
            }

            if (errno == ECHILD) {
                sleep(1);
                continue;
            }

            perror("waitpid");
            return EXIT_FAILURE;
        }

        if (WIFEXITED(status)) {
            printf("Waited for child PID %ld.  Its exit status is %d.\n", (long)pid, WEXITSTATUS(status));
        } else if (WIFSIGNALED(status)) {
            printf("Child PID %ld terminated by signal %d\n", (long)pid, WTERMSIG(status));
        }
    }

    return EXIT_SUCCESS;
}
