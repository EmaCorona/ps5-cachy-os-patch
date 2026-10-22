/* ==============================================================================
 * resources/m2/ps5-nvme-ctl.c - Helper autonomo NVMe Admin per PlayStation 5
 * ==============================================================================
 * Gestione dello standard NVMe Namespace Write Protection (Feature ID 0x84).
 * Interagisce direttamente con il driver NVMe Linux tramite NVME_IOCTL_ADMIN_CMD.
 * Zero dipendenze esterne: compatibile con l'ambiente early-boot (ash) e shutdown.
 * ==============================================================================
 */

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <linux/fs.h>
#include <linux/nvme_ioctl.h>

#ifndef BLKROSET
#define BLKROSET _IO(0x12, 93)
#endif
#ifndef BLKROGET
#define BLKROGET _IO(0x12, 94)
#endif

#define NVME_ADMIN_IDENTIFY     0x06
#define NVME_ADMIN_SET_FEATURES 0x09
#define NVME_ADMIN_GET_FEATURES 0x0A

#define NVME_FEAT_WRITE_PROTECT 0x84

#define STATE_NO_PROTECT               0
#define STATE_WRITE_PROTECT_REVERSIBLE 1
#define STATE_WRITE_PROTECT_PWR_CYCLE  2
#define STATE_PERMANENT_WRITE_PROTECT  3

static void trim_trailing_spaces(char *str, size_t len) {
    if (len == 0) return;
    int i = (int)len - 1;
    while (i >= 0 && (str[i] == ' ' || str[i] == '\0' || str[i] == '\r' || str[i] == '\n')) {
        str[i] = '\0';
        i--;
    }
}

static uint32_t get_nsid(int fd, const char *arg_nsid, uint32_t auto_nsid) {
    if (arg_nsid != NULL && arg_nsid[0] != '\0') {
        unsigned long n = strtoul(arg_nsid, NULL, 0);
        if (n > 0) return (uint32_t)n;
    }
    if (auto_nsid > 0) return auto_nsid;
    int nsid = ioctl(fd, NVME_IOCTL_ID);
    if (nsid > 0) return (uint32_t)nsid;
    return 1;
}

/* --------------------------------------------------------------------------
 * Risoluzione nodi controller char device e namespace block device
 * -------------------------------------------------------------------------- */
static void resolve_controller_and_ns(const char *input_path,
                                     char *ctrl_path, size_t ctrl_len,
                                     char *blk_path, size_t blk_len,
                                     uint32_t *auto_nsid) {
    if (ctrl_path && ctrl_len > 0) ctrl_path[0] = '\0';
    if (blk_path && blk_len > 0) blk_path[0] = '\0';
    if (auto_nsid) *auto_nsid = 0;

    if (!input_path || input_path[0] == '\0') return;

    const char *base = strrchr(input_path, '/');
    base = (base != NULL) ? base + 1 : input_path;

    /* 1. Controllo sysfs: se input_path è un block device associato a un controller */
    char sysfs_device[512];
    snprintf(sysfs_device, sizeof(sysfs_device), "/sys/class/block/%s/device", base);
    char link_target[512];
    ssize_t llen = readlink(sysfs_device, link_target, sizeof(link_target) - 1);
    if (llen > 0) {
        link_target[llen] = '\0';
        char *cname = strrchr(link_target, '/');
        cname = (cname != NULL) ? cname + 1 : link_target;
        if (strncmp(cname, "nvme", 4) == 0 && isdigit((unsigned char)cname[4])) {
            if (ctrl_path && ctrl_len > 0) {
                snprintf(ctrl_path, ctrl_len, "/dev/%.64s", cname);
            }
        }
    }

    /* 2. Parsing sintattico convenzionale per dispositivi NVMe Linux (es: /dev/nvme0n1p1) */
    if (strncmp(base, "nvme", 4) == 0 && isdigit((unsigned char)base[4])) {
        const char *p = base + 4;
        while (*p && isdigit((unsigned char)*p)) p++;

        if (ctrl_path && (ctrl_path[0] == '\0')) {
            size_t cname_len = (size_t)(p - base);
            char cname[64];
            if (cname_len < sizeof(cname)) {
                memcpy(cname, base, cname_len);
                cname[cname_len] = '\0';
                snprintf(ctrl_path, ctrl_len, "/dev/%s", cname);
            }
        }

        if (*p == 'n') {
            p++;
            unsigned long ns_num = strtoul(p, NULL, 10);
            if (auto_nsid && ns_num > 0) *auto_nsid = (uint32_t)ns_num;

            if (blk_path && blk_len > 0) {
                const char *end_ns = p;
                while (*end_ns && isdigit((unsigned char)*end_ns)) end_ns++;
                size_t blk_part_len = (size_t)(end_ns - base);
                char clean_blk[64];
                if (blk_part_len < sizeof(clean_blk)) {
                    memcpy(clean_blk, base, blk_part_len);
                    clean_blk[blk_part_len] = '\0';
                    snprintf(blk_path, blk_len, "/dev/%s", clean_blk);
                }
            }
        } else if (*p == '\0') {
            if (ctrl_path && ctrl_len > 0) {
                snprintf(ctrl_path, ctrl_len, "%s", input_path);
            }
        }
    }
}

static int do_set_device_rw(const char *blk_path, const char *mock_file);

/* --------------------------------------------------------------------------
 * Gestione Mock per Sandbox Test Suite Hardware-Free
 * -------------------------------------------------------------------------- */
static const char *get_mock_file(void) {
    const char *mf = getenv("PS5_NVME_MOCK_FILE");
    if (mf != NULL && mf[0] != '\0') return mf;
    return NULL;
}

static int mock_read_key(const char *mock_file, const char *key, char *out_val, size_t max_len) {
    FILE *f = fopen(mock_file, "r");
    if (!f) return -1;
    char line[512];
    size_t klen = strlen(key);
    int found = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
            char *v = line + klen + 1;
            char *nl = strchr(v, '\n');
            if (nl) *nl = '\0';
            nl = strchr(v, '\r');
            if (nl) *nl = '\0';
            strncpy(out_val, v, max_len - 1);
            out_val[max_len - 1] = '\0';
            found = 1;
            break;
        }
    }
    fclose(f);
    return found ? 0 : -1;
}

static int mock_set_key(const char *mock_file, const char *key, const char *new_val) {
    FILE *f = fopen(mock_file, "r");
    if (!f) return -1;
    char lines[64][512];
    int line_count = 0;
    size_t klen = strlen(key);
    int updated = 0;

    while (line_count < 64 && fgets(lines[line_count], sizeof(lines[0]), f)) {
        if (strncmp(lines[line_count], key, klen) == 0 && lines[line_count][klen] == '=') {
            snprintf(lines[line_count], sizeof(lines[0]), "%s=%s\n", key, new_val);
            updated = 1;
        }
        line_count++;
    }
    fclose(f);

    if (!updated && line_count < 64) {
        snprintf(lines[line_count++], sizeof(lines[0]), "%s=%s\n", key, new_val);
    }

    f = fopen(mock_file, "w");
    if (!f) return -1;
    for (int i = 0; i < line_count; i++) {
        fputs(lines[i], f);
    }
    fclose(f);
    return 0;
}

/* --------------------------------------------------------------------------
 * Reset flag read-only a livello kernel block layer (BLKROSET) e rescan
 * -------------------------------------------------------------------------- */
static int do_set_device_rw(const char *blk_path, const char *mock_file) {
    if (mock_file) {
        mock_set_key(mock_file, "BLK_RO", "0");
        printf("SET_RW=OK\n");
        return 0;
    }

    if (!blk_path || blk_path[0] == '\0') {
        fprintf(stderr, "Errore: percorso block device non specificato per set-rw\n");
        return 1;
    }

    /* Apertura in O_RDONLY: BLKROSET richiede privilegi di root ma non O_RDWR,
     * permettendo di sbloccare il flag anche quando il block device è marcato EROFS */
    int fd = open(blk_path, O_RDONLY);
    if (fd < 0) {
        perror("open block device (set-rw)");
        return 1;
    }

    int zero = 0;
    if (ioctl(fd, BLKROSET, &zero) < 0) {
        perror("ioctl BLKROSET");
        close(fd);
        return 1;
    }
    close(fd);

    /* Notifica del rescan controller al driver NVMe per aggiornare la cache del kernel */
    const char *base = strrchr(blk_path, '/');
    base = (base != NULL) ? base + 1 : blk_path;
    char sysfs_rescan[512];
    snprintf(sysfs_rescan, sizeof(sysfs_rescan), "/sys/class/block/%s/device/rescan_controller", base);
    FILE *rf = fopen(sysfs_rescan, "w");
    if (rf) {
        fputs("1\n", rf);
        fclose(rf);
    }

    printf("SET_RW=OK\n");
    return 0;
}

/* --------------------------------------------------------------------------
 * Apertura del descrittore per comandi di amministrazione NVMe
 * -------------------------------------------------------------------------- */
static int open_nvme_admin_fd(const char *dev_path,
                              char *out_ctrl_path, size_t ctrl_len,
                              char *out_blk_path, size_t blk_len,
                              uint32_t *auto_nsid) {
    resolve_controller_and_ns(dev_path, out_ctrl_path, ctrl_len, out_blk_path, blk_len, auto_nsid);

    /* 1. Se è disponibile il nodo controller character device (/dev/nvme0),
     * apriamo prioritariamente quello in O_RDWR.
     * I comandi NVME_IOCTL_ADMIN_CMD sono indirizzati alla admin queue del controller
     * e non subiscono il blocco EROFS del kernel block layer! */
    if (out_ctrl_path && out_ctrl_path[0] != '\0') {
        struct stat st_ctrl;
        if (stat(out_ctrl_path, &st_ctrl) == 0 && S_ISCHR(st_ctrl.st_mode)) {
            int fd = open(out_ctrl_path, O_RDWR);
            if (fd < 0 && (errno == EROFS || errno == EACCES)) {
                fd = open(out_ctrl_path, O_RDONLY);
            }
            if (fd >= 0) {
                return fd;
            }
        }
    }

    /* 2. Fallback: apertura del dispositivo originale fornito */
    struct stat st;
    if (stat(dev_path, &st) == -1) {
        perror("stat device");
        return -1;
    }

    int fd = open(dev_path, O_RDWR);
    if (fd < 0) {
        /* Se fallisce con EROFS/EACCES (es. namespace a blocchi protetto in sola lettura),
         * tentiamo l'apertura in O_RDONLY: il kernel Linux permette l'ioctl admin su fd O_RDONLY */
        fd = open(dev_path, O_RDONLY);
    }

    if (fd < 0) {
        perror("open device");
        return -1;
    }

    return fd;
}

/* --------------------------------------------------------------------------
 * Comandi Hardware NVMe Admin
 * -------------------------------------------------------------------------- */
static int do_identify_ctrl(int fd, const char *mock_file) {
    if (mock_file) {
        char mn[128] = "Samsung SSD 980 PRO 1TB";
        char sn[128] = "S5GXNF0R123456";
        char fr[128] = "5B2QGXA7";
        char nwpc_s[128] = "1";

        mock_read_key(mock_file, "MN", mn, sizeof(mn));
        mock_read_key(mock_file, "SN", sn, sizeof(sn));
        mock_read_key(mock_file, "FR", fr, sizeof(fr));
        mock_read_key(mock_file, "NWPC", nwpc_s, sizeof(nwpc_s));

        unsigned long nwpc_val = strtoul(nwpc_s, NULL, 0);
        printf("MN=%s\n", mn);
        printf("SN=%s\n", sn);
        printf("FR=%s\n", fr);
        printf("NWPC=0x%02lx\n", nwpc_val);
        printf("NWPC_REVERSIBLE=%d\n", (nwpc_val & 0x01) ? 1 : 0);
        printf("NWPC_POWER_CYCLE=%d\n", (nwpc_val & 0x02) ? 1 : 0);
        printf("NWPC_PERMANENT=%d\n", (nwpc_val & 0x04) ? 1 : 0);
        return 0;
    }

    uint8_t buf[4096];
    memset(buf, 0, sizeof(buf));

    struct nvme_admin_cmd cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = NVME_ADMIN_IDENTIFY;
    cmd.nsid = 0;
    cmd.addr = (uint64_t)(uintptr_t)buf;
    cmd.data_len = sizeof(buf);
    cmd.cdw10 = 1; /* CNS = 1: Identify Controller */

    if (ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
        perror("ioctl NVME_ADMIN_IDENTIFY (controller)");
        return 1;
    }

    char sn[21];
    char mn[41];
    char fr[9];

    memcpy(sn, buf + 4, 20);
    sn[20] = '\0';
    trim_trailing_spaces(sn, 20);

    memcpy(mn, buf + 24, 40);
    mn[40] = '\0';
    trim_trailing_spaces(mn, 40);

    memcpy(fr, buf + 64, 8);
    fr[8] = '\0';
    trim_trailing_spaces(fr, 8);

    uint8_t nwpc = buf[531];

    printf("MN=%s\n", mn);
    printf("SN=%s\n", sn);
    printf("FR=%s\n", fr);
    printf("NWPC=0x%02x\n", nwpc);
    printf("NWPC_REVERSIBLE=%d\n", (nwpc & 0x01) ? 1 : 0);
    printf("NWPC_POWER_CYCLE=%d\n", (nwpc & 0x02) ? 1 : 0);
    printf("NWPC_PERMANENT=%d\n", (nwpc & 0x04) ? 1 : 0);
    return 0;
}

static int do_identify_ns(int fd, uint32_t nsid, const char *mock_file) {
    if (mock_file) {
        char nsze[64] = "2000409264";
        char ncap[64] = "2000409264";
        char nguid[64] = "002538b123456789";
        char eui64[64] = "0025381234567890";

        mock_read_key(mock_file, "NSZE", nsze, sizeof(nsze));
        mock_read_key(mock_file, "NCAP", ncap, sizeof(ncap));
        mock_read_key(mock_file, "NGUID", nguid, sizeof(nguid));
        mock_read_key(mock_file, "EUI64", eui64, sizeof(eui64));

        printf("NSID=%" PRIu32 "\n", nsid);
        printf("NSZE=%s\n", nsze);
        printf("NCAP=%s\n", ncap);
        printf("NGUID=%s\n", nguid);
        printf("EUI64=%s\n", eui64);
        return 0;
    }

    uint8_t buf[4096];
    memset(buf, 0, sizeof(buf));

    struct nvme_admin_cmd cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = NVME_ADMIN_IDENTIFY;
    cmd.nsid = nsid;
    cmd.addr = (uint64_t)(uintptr_t)buf;
    cmd.data_len = sizeof(buf);
    cmd.cdw10 = 0; /* CNS = 0: Identify Namespace */

    if (ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
        perror("ioctl NVME_ADMIN_IDENTIFY (namespace)");
        return 1;
    }

    uint64_t nsze = *(uint64_t *)(buf + 0);
    uint64_t ncap = *(uint64_t *)(buf + 8);

    char nguid_str[33] = {0};
    for (int i = 0; i < 16; i++) {
        sprintf(nguid_str + (i * 2), "%02x", buf[104 + i]);
    }

    char eui64_str[17] = {0};
    for (int i = 0; i < 8; i++) {
        sprintf(eui64_str + (i * 2), "%02x", buf[120 + i]);
    }

    printf("NSID=%" PRIu32 "\n", nsid);
    printf("NSZE=%" PRIu64 "\n", nsze);
    printf("NCAP=%" PRIu64 "\n", ncap);
    printf("NGUID=%s\n", nguid_str);
    printf("EUI64=%s\n", eui64_str);
    return 0;
}

static int do_get_feature_wp(int fd, uint32_t nsid, const char *mock_file, uint32_t *out_val) {
    if (mock_file) {
        char fail_s[64] = "0";
        mock_read_key(mock_file, "FAIL_GET_FEATURE", fail_s, sizeof(fail_s));
        if (strcmp(fail_s, "1") == 0) {
            fprintf(stderr, "Mock error: Controller refused Get Feature 0x84\n");
            return 1;
        }

        char st_s[64] = "0";
        mock_read_key(mock_file, "WP_STATE", st_s, sizeof(st_s));
        uint32_t v = (uint32_t)strtoul(st_s, NULL, 0);
        if (out_val) *out_val = v;

        const char *desc = "UNKNOWN";
        if (v == STATE_NO_PROTECT) desc = "NO_PROTECT";
        else if (v == STATE_WRITE_PROTECT_REVERSIBLE) desc = "WRITE_PROTECT";
        else if (v == STATE_WRITE_PROTECT_PWR_CYCLE) desc = "WRITE_PROTECT_PWR_CYCLE";
        else if (v == STATE_PERMANENT_WRITE_PROTECT) desc = "PERMANENT_WRITE_PROTECT";

        printf("FEATURE_0X84_RAW=0x%08x\n", v);
        printf("WP_STATE=%" PRIu32 "\n", v);
        printf("WP_STATE_DESC=%s\n", desc);
        return 0;
    }

    struct nvme_admin_cmd cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = NVME_ADMIN_GET_FEATURES;
    cmd.nsid = nsid;
    cmd.cdw10 = NVME_FEAT_WRITE_PROTECT;

    if (ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
        perror("ioctl NVME_ADMIN_GET_FEATURES (0x84)");
        return 1;
    }

    uint32_t v = cmd.result & 0x07;
    if (out_val) *out_val = v;

    const char *desc = "UNKNOWN";
    if (v == STATE_NO_PROTECT) desc = "NO_PROTECT";
    else if (v == STATE_WRITE_PROTECT_REVERSIBLE) desc = "WRITE_PROTECT";
    else if (v == STATE_WRITE_PROTECT_PWR_CYCLE) desc = "WRITE_PROTECT_PWR_CYCLE";
    else if (v == STATE_PERMANENT_WRITE_PROTECT) desc = "PERMANENT_WRITE_PROTECT";

    printf("FEATURE_0X84_RAW=0x%08x\n", cmd.result);
    printf("WP_STATE=%" PRIu32 "\n", v);
    printf("WP_STATE_DESC=%s\n", desc);
    return 0;
}

static int do_set_feature_wp(int fd, uint32_t nsid, uint32_t target_state,
                             const char *blk_path, const char *mock_file) {
    /* ----------------------------------------------------------------------
     * BLOCCO DI SICUREZZA FISICO E IMPRESCINDIBILE:
     * Lo standard NVMe permette stati 0, 1, 2, 3.
     * La policy PS5 vieta tassativamente 2 e 3 per evitare brick irreversibili.
     * ---------------------------------------------------------------------- */
    if (target_state != STATE_NO_PROTECT && target_state != STATE_WRITE_PROTECT_REVERSIBLE) {
        fprintf(stderr, "FATAL SECURITY ERROR: Tentativo di impostare stato di protezione NVMe %" PRIu32 " NON CONSENTITO!\n"
                        "Sono autorizzati esclusivamente lo stato 0 (sbloccato) e lo stato 1 (reversibile).\n", target_state);
        return 2;
    }

    if (mock_file) {
        char fail_s[64] = "0";
        mock_read_key(mock_file, "REJECT_SET_FEATURE", fail_s, sizeof(fail_s));
        if (strcmp(fail_s, "1") == 0) {
            fprintf(stderr, "Mock error: Controller Set Feature 0x84 rejected by firmware.\n");
            return 1;
        }

        char st_str[32];
        snprintf(st_str, sizeof(st_str), "%" PRIu32, target_state);
        if (mock_set_key(mock_file, "WP_STATE", st_str) != 0) {
            fprintf(stderr, "Mock error: impossibile salvare WP_STATE in %s\n", mock_file);
            return 1;
        }

        uint32_t verified_state = 999;
        if (do_get_feature_wp(fd, nsid, mock_file, &verified_state) != 0) {
            fprintf(stderr, "Errore verifica post Set-Feature\n");
            return 1;
        }
        if (verified_state != target_state) {
            fprintf(stderr, "VERIFICATION FAILED: Controller ha restituito stato %" PRIu32 " invece di %" PRIu32 "\n", verified_state, target_state);
            return 1;
        }

        if (target_state == STATE_NO_PROTECT) {
            mock_set_key(mock_file, "BLK_RO", "0");
        }

        printf("SET_FEATURE_0X84=OK\n");
        return 0;
    }

    struct nvme_admin_cmd cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = NVME_ADMIN_SET_FEATURES;
    cmd.nsid = nsid;
    cmd.cdw10 = NVME_FEAT_WRITE_PROTECT;
    cmd.cdw11 = target_state;

    if (ioctl(fd, NVME_IOCTL_ADMIN_CMD, &cmd) < 0) {
        perror("ioctl NVME_ADMIN_SET_FEATURES (0x84)");
        return 1;
    }

    /* Verifica post-comando obbligatoria tramite Get Features */
    uint32_t verified_state = 999;
    if (do_get_feature_wp(fd, nsid, NULL, &verified_state) != 0) {
        fprintf(stderr, "Errore: lettura stato di verifica post Set-Feature fallita.\n");
        return 1;
    }

    if (verified_state != target_state) {
        fprintf(stderr, "VERIFICATION FAILED: Il controller ha impostato stato %" PRIu32 " anziché %" PRIu32 " richiesto!\n", verified_state, target_state);
        return 1;
    }

    /* Se lo sblocco ha avuto successo (stato 0), sincronizza e azzera il flag RO del block device nel kernel */
    if (target_state == STATE_NO_PROTECT && blk_path && blk_path[0] != '\0') {
        do_set_device_rw(blk_path, NULL);
    }

    printf("SET_FEATURE_0X84=OK\n");
    return 0;
}

static void show_usage(const char *prog) {
    fprintf(stderr,
        "Uso / Usage: %s <comando> <device> [opzioni...]\n\n"
        "Comandi disponibili:\n"
        "  id-ctrl <dev>              Interroga Identify Controller (modello, seriale, NWPC)\n"
        "  id-ns <dev> [nsid]         Interroga Identify Namespace (dimensione, NGUID, EUI64)\n"
        "  get-feature <dev> [nsid]   Legge lo stato corrente della protezione (Feature 0x84)\n"
        "  set-feature <dev> <0|1> [nsid]\n"
        "                             Imposta protezione: 0 = sbloccato, 1 = reversibile\n"
        "                             (Accetta tassativamente solo '0' o '1')\n"
        "  set-rw <block-dev>         Azzera flag read-only del kernel (BLKROSET) e forza rescan\n",
        prog);
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        show_usage(argv[0]);
        return EXIT_FAILURE;
    }

    const char *cmd = argv[1];
    const char *dev_path = argv[2];
    const char *mock_file = get_mock_file();

    /* ----------------------------------------------------------------------
     * VALIDAZIONE PREVENTIVA RIGOROSA DEGLI ARGOMENTI (PRIMA DELL'APERTURA)
     * ---------------------------------------------------------------------- */
    uint32_t target_val = 0;
    if (strcmp(cmd, "set-feature") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Errore: 'set-feature' richiede il valore desiderato (0 oppure 1)\n");
            return EXIT_FAILURE;
        }
        /* Rifiuto categorico di qualsiasi stringa diversa da "0" o "1" */
        if (strcmp(argv[3], "0") != 0 && strcmp(argv[3], "1") != 0) {
            fprintf(stderr, "FATAL SECURITY ERROR: Argomento '%s' non valido per 'set-feature'!\n"
                            "Accettati esclusivamente i valori testuali esatti '0' (sblocco) o '1' (protezione reversibile).\n",
                            argv[3]);
            return 2;
        }
        target_val = (argv[3][0] == '1') ? 1 : 0;
    }

    /* Comando autonomo set-rw non necessita del descrittore admin ioctl */
    if (strcmp(cmd, "set-rw") == 0) {
        return do_set_device_rw(dev_path, mock_file);
    }

    /* Risoluzione del controller e del namespace */
    char ctrl_path[256] = {0};
    char blk_path[256] = {0};
    uint32_t auto_nsid = 0;
    int fd = -1;

    if (!mock_file) {
        fd = open_nvme_admin_fd(dev_path, ctrl_path, sizeof(ctrl_path), blk_path, sizeof(blk_path), &auto_nsid);
        if (fd < 0) {
            return EXIT_FAILURE;
        }
    }

    int rc = EXIT_FAILURE;

    if (strcmp(cmd, "id-ctrl") == 0) {
        rc = do_identify_ctrl(fd, mock_file);
    } else if (strcmp(cmd, "id-ns") == 0) {
        const char *ns_arg = (argc >= 4) ? argv[3] : NULL;
        uint32_t nsid = get_nsid(fd, ns_arg, auto_nsid);
        rc = do_identify_ns(fd, nsid, mock_file);
    } else if (strcmp(cmd, "get-feature") == 0) {
        const char *ns_arg = (argc >= 4) ? argv[3] : NULL;
        uint32_t nsid = get_nsid(fd, ns_arg, auto_nsid);
        rc = do_get_feature_wp(fd, nsid, mock_file, NULL);
    } else if (strcmp(cmd, "set-feature") == 0) {
        const char *ns_arg = (argc >= 5) ? argv[4] : NULL;
        uint32_t nsid = get_nsid(fd, ns_arg, auto_nsid);
        const char *target_blk = (blk_path[0] != '\0') ? blk_path : dev_path;
        rc = do_set_feature_wp(fd, nsid, target_val, target_blk, mock_file);
    } else {
        fprintf(stderr, "Comando sconosciuto: %s\n", cmd);
        show_usage(argv[0]);
        rc = EXIT_FAILURE;
    }

    if (fd >= 0) close(fd);
    return rc;
}
