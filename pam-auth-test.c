#define _POSIX_C_SOURCE 200809L

#include <security/pam_appl.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int converse(int count, const struct pam_message **messages,
                    struct pam_response **responses, void *unused) {
    struct pam_response *reply;
    int index;

    (void)unused;
    if (count <= 0) {
        return PAM_CONV_ERR;
    }
    reply = calloc((size_t)count, sizeof(*reply));
    if (reply == NULL) {
        return PAM_BUF_ERR;
    }

    for (index = 0; index < count; ++index) {
        if (messages[index]->msg != NULL) {
            fputs(messages[index]->msg, stderr);
        }
        if (messages[index]->msg_style == PAM_PROMPT_ECHO_ON ||
            messages[index]->msg_style == PAM_PROMPT_ECHO_OFF) {
            reply[index].resp = strdup("");
            if (reply[index].resp == NULL) {
                while (index-- > 0) {
                    free(reply[index].resp);
                }
                free(reply);
                return PAM_BUF_ERR;
            }
        }
    }
    *responses = reply;
    return PAM_SUCCESS;
}

int main(int argc, char **argv) {
    const struct pam_conv conversation = {converse, NULL};
    pam_handle_t *handle = NULL;
    int result;

    if (argc != 3) {
        fprintf(stderr, "Usage: %s PAM_SERVICE USER\n", argv[0]);
        return 2;
    }

    result = pam_start(argv[1], argv[2], &conversation, &handle);
    if (result == PAM_SUCCESS) {
        result = pam_authenticate(handle, 0);
    }
    if (result == PAM_SUCCESS) {
        result = pam_acct_mgmt(handle, 0);
    }
    if (result != PAM_SUCCESS) {
        fprintf(stderr, "\nPAM test failed: %s\n", pam_strerror(handle, result));
    } else {
        fputs("\nPAM test succeeded.\n", stderr);
    }
    if (handle != NULL) {
        pam_end(handle, result);
    }
    return result == PAM_SUCCESS ? 0 : 1;
}
