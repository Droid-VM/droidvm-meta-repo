// captest: verify (a) AMFI accepts a large entitlement blob and reports it back, and
// (b) this kernel honours posix_spawn into a root persona (the privileged-app helper path).
//   captest ents         -- print the kernel's view of our granted entitlements (csops blob): size + key count
//   captest persona      -- posix_spawn a child into persona uid 0 and report its uid/euid; also after seteuid(501)
//   captest whoami       -- print uid/euid/persona (used as the spawned child)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <errno.h>
#include <sys/wait.h>
#include <stdint.h>

extern char **environ;

// csops
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_ENTITLEMENTS_BLOB 7

// persona spawnattr SPI (libsyscall)
extern int posix_spawnattr_set_persona_np(posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(posix_spawnattr_t *, gid_t);
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1

// kpersona SPI (bsd/sys/persona.h, exported from libsystem_kernel) -- struct is ABI-fixed at 348 bytes
#define NGROUPS_P 16
#define MAXLOGNAME_P 255
#define PERSONA_INFO_V2 2
struct kpersona_info {
    uint32_t persona_info_version;
    uid_t    persona_id;
    int      persona_type;
    gid_t    persona_gid;
    uint32_t persona_ngroups;
    gid_t    persona_groups[NGROUPS_P];
    uid_t    persona_gmuid;
    char     persona_name[MAXLOGNAME_P + 1];
    uid_t    persona_uid;
};
extern int kpersona_find(const char *name, uid_t uid, uid_t *id, size_t *idlen);
extern int kpersona_info(uid_t id, struct kpersona_info *info);
extern int kpersona_pidinfo(pid_t pid, struct kpersona_info *info);
extern int kpersona_find_by_type(int persona_type, uid_t *id, size_t *idlen);
extern int kpersona_alloc(struct kpersona_info *info, uid_t *id);
#define PERSONA_PRIV 3
#define PERSONA_SYSTEM 4
#define PERSONA_DEFAULT 5
static const char *ptype(int t) {
    const char *n[] = {"INVALID","GUEST","MANAGED","PRIV","SYSTEM","DEFAULT","SYSTEM_PROXY","SYS_EXT","ENTERPRISE"};
    return (t >= 0 && t <= 8) ? n[t] : "?";
}

#define SELF "/private/var/ngpu/bin/captest"

static int do_whoami(const char *tag) {
    printf("%s uid=%d euid=%d gid=%d egid=%d\n", tag, getuid(), geteuid(), getgid(), getegid());
    fflush(stdout);
    return 0;
}

static int do_ents(void) {
    size_t cap = 2 * 1024 * 1024;
    unsigned char *buf = calloc(1, cap);
    if (!buf) return 2;
    int r = csops(getpid(), CS_OPS_ENTITLEMENTS_BLOB, buf, cap);
    int e = errno;
    uint32_t magic = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
    uint32_t len = (buf[4] << 24) | (buf[5] << 16) | (buf[6] << 8) | buf[7];
    printf("ents: csops r=%d errno=%d (%s) magic=0x%08x blob_len=%u\n",
           r, e, r ? strerror(e) : "-", magic, len);
    if (magic == 0xfade7171 && len >= 8 && len <= cap) {
        const char *xml = (const char *)buf + 8;
        size_t xlen = len - 8;
        size_t keys = 0;
        for (size_t i = 0; i + 5 <= xlen; i++)
            if (memcmp(xml + i, "<key>", 5) == 0) keys++;
        printf("ents: granted keys (by <key> count) = %zu\n", keys);
        // list every granted key name, so a stripped entitlement is obvious
        const char *p = xml, *end = xml + xlen;
        while (p < end) {
            const char *o = memmem(p, (size_t)(end - p), "<key>", 5);
            if (!o) break;
            o += 5;
            const char *c = memmem(o, (size_t)(end - o), "</key>", 6);
            if (!c) break;
            printf("  %.*s\n", (int)(c - o), o);
            p = c + 6;
        }
    }
    free(buf);
    return 0;
}

// Spawn a child adopting persona `pid_persona` with uid/gid overridden to `ovr`. label describes the case.
static int spawn_child(uid_t pid_persona, uid_t ovr, const char *label) {
    char *self = SELF;
    char *argv[] = {self, "whoami", NULL};
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    int e1 = posix_spawnattr_set_persona_np(&attr, pid_persona, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    int e2 = posix_spawnattr_set_persona_uid_np(&attr, ovr);
    int e3 = posix_spawnattr_set_persona_gid_np(&attr, ovr);
    pid_t pid = 0;
    int sr = posix_spawn(&pid, self, NULL, &attr, argv, environ);
    printf("persona[%s] id=%u ovr_uid=%u: set=%d/%d/%d spawn=%d(%s) pid=%d\n",
           label, pid_persona, ovr, e1, e2, e3, sr, sr ? strerror(sr) : "ok", pid);
    fflush(stdout);
    if (sr == 0) { int st = 0; waitpid(pid, &st, 0); }
    posix_spawnattr_destroy(&attr);
    return sr;
}

static void list_personas(void) {
    struct kpersona_info info;
    info.persona_info_version = PERSONA_INFO_V2;
    if (kpersona_pidinfo(getpid(), &info) == 0)
        printf("my persona: id=%u type=%s(%d) uid=%u name='%s'\n",
               info.persona_id, ptype(info.persona_type), info.persona_type, info.persona_uid, info.persona_name);
    else
        printf("kpersona_pidinfo(self) errno=%d (%s)\n", errno, strerror(errno));
    for (int t = 1; t <= 8; t++) {
        uid_t ids[64]; size_t n = 64;
        if (kpersona_find_by_type(t, ids, &n) == 0 && n) {
            printf("type %s(%d): %zu persona(s):", ptype(t), t, n);
            for (size_t i = 0; i < n && i < 64; i++) {
                struct kpersona_info pi; pi.persona_info_version = PERSONA_INFO_V2;
                if (kpersona_info(ids[i], &pi) == 0) printf(" id=%u(uid=%u '%s')", ids[i], pi.persona_uid, pi.persona_name);
                else printf(" id=%u", ids[i]);
            }
            printf("\n");
        }
    }
}

static uid_t find_root_persona(void) {
    // prefer the SYSTEM persona, else any persona whose uid is 0
    for (int t = 4; t <= 8; t++) {
        uid_t ids[64]; size_t n = 64;
        if (kpersona_find_by_type(t, ids, &n) == 0 && n) {
            for (size_t i = 0; i < n && i < 64; i++) {
                struct kpersona_info pi; pi.persona_info_version = PERSONA_INFO_V2;
                if (kpersona_info(ids[i], &pi) == 0 && pi.persona_uid == 0) return ids[i];
            }
            return ids[0];
        }
    }
    uid_t ids[64]; size_t n = 64;
    if (kpersona_find(NULL, 0, ids, &n) == 0 && n) return ids[0];
    return PERSONA_INFO_V2 * 0; // 0 = none
}

// With persona-mgmt, create a uid-0 persona we can then adopt. Returns its id or 0.
static uid_t alloc_root_persona(void) {
    int types[] = {PERSONA_DEFAULT, PERSONA_SYSTEM, PERSONA_PRIV};
    const char *names[] = {"dvmdbgroot", "dvmdbgsys", "dvmdbgpriv"};
    for (unsigned i = 0; i < 3; i++) {
        struct kpersona_info info;
        memset(&info, 0, sizeof info);
        info.persona_info_version = PERSONA_INFO_V2;
        info.persona_type = types[i];
        info.persona_uid = 0;
        info.persona_gid = 0;
        strncpy(info.persona_name, names[i], MAXLOGNAME_P);
        uid_t id = 0;
        int r = kpersona_alloc(&info, &id);
        printf("kpersona_alloc(type=%s uid=0) r=%d errno=%d(%s) id=%u\n",
               ptype(types[i]), r, errno, strerror(errno), id);
        if (r == 0 && id) return id;
    }
    return 0;
}

static int do_persona(int argc, char **argv) {
    do_whoami("caller");
    list_personas();
    uid_t rp = (argc > 2) ? (uid_t)atoi(argv[2]) : find_root_persona();
    if (rp == 0) {
        printf("no existing persona; allocating one via persona-mgmt\n");
        rp = alloc_root_persona();
    }
    printf("using root persona id=%u\n", rp);
    // (1) as root: adopt the root persona, override uid/gid 0
    spawn_child(rp, 0, "root->root");
    // (2) euid-only drop, then spawn a root child via persona override
    if (seteuid(501) == 0) {
        printf("dropped euid to %d; now spawning a root child via persona\n", geteuid());
        spawn_child(rp, 0, "mobile(euid)->root");
        if (seteuid(0) != 0) printf("could not restore euid 0\n");
    } else {
        printf("seteuid(501) failed errno=%d (%s)\n", errno, strerror(errno));
    }
    // (3) the real SpringBoard-app case: a fully-mobile child (ruid=euid=svuid=501) tries to spawn root via persona
    pid_t f = fork();
    if (f == 0) {
        setgid(501);
        if (setuid(501) != 0) { printf("setuid(501) failed errno=%d\n", errno); _exit(1); }
        printf("fully-mobile child uid=%d euid=%d: spawning root via persona id=%u\n", getuid(), geteuid(), rp);
        spawn_child(rp, 0, "fullmobile->root");
        _exit(0);
    } else if (f > 0) {
        int st = 0;
        waitpid(f, &st, 0);
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "whoami";
    if (!strcmp(cmd, "whoami")) return do_whoami("whoami");
    if (!strcmp(cmd, "ents")) return do_ents();
    if (!strcmp(cmd, "persona")) return do_persona(argc, argv);
    if (!strcmp(cmd, "personas")) { list_personas(); return 0; }
    fprintf(stderr, "usage: captest ents|persona|whoami\n");
    return 1;
}
