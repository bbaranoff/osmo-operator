/*
 * osmo-rild.c - LE CHAINON MANQUANT ENTRE ANDROID ET LE MODEM DU BANC.
 *
 * Pourquoi ce programme existe. L image Waydroid (LineageOS 20, Android 13,
 * x86_64) embarque TOUTE la pile RIL sauf le programme qui la met en marche :
 *
 *   /vendor/lib64/libril.so            present - le pont vers le framework,
 *                                      en HIDL (il depend de
 *                                      android.hardware.radio@1.0 et @1.1, les
 *                                      deux seules versions que cette image
 *                                      possede). Exporte RIL_register,
 *                                      RIL_startEventLoop, RIL_onRequestComplete,
 *                                      RIL_onUnsolicitedResponse.
 *   /vendor/lib64/libreference-ril.so  present - l implementation qui parle AT
 *                                      sur un port serie. Exporte RIL_Init.
 *   /vendor/bin/hw/rild                ABSENT. C est tout ce qui manquait.
 *
 * rild ne fait presque rien : il demarre la boucle d evenements de libril,
 * appelle RIL_Init de l implementation en lui passant un RIL_Env (les quatre
 * fonctions par lesquelles elle repond au framework), puis enregistre les
 * fonctions rendues. Une cinquantaine de lignes - d ou le choix de le compiler
 * plutot que de courir apres un binaire d une autre image, dont l ABI ne
 * correspondrait pas forcement.
 *
 * Le rild de l emulateur Android 13 (libgoldfish-rild) ne convenait PAS : il
 * passe par libril-modem-lib.so et les HAL radio en AIDL, absentes de cette
 * image. Ici tout reste en HIDL, comme la pile de Waydroid.
 *
 * Usage (identique au rild d AOSP) :
 *   osmo-rild -l /vendor/lib64/libreference-ril.so -- -d /dev/at-pty
 *
 * ou /dev/at-pty est le pseudo-terminal publie par tools/osmo-ril-atmodem.py,
 * c est-a-dire oFono, c est-a-dire le banc.
 *
 * Compilation : tools/rild/build.sh (NDK, cible android33 x86_64).
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>

#include <telephony/ril.h>

#define LIBRIL "libril.so"

static void (*p_startEventLoop)(void);
static void (*p_register)(const RIL_RadioFunctions *);
static void (*p_onRequestComplete)(RIL_Token, RIL_Errno, void *, size_t);
static void (*p_onUnsolicitedResponse)(int, const void *, size_t);
static void (*p_requestTimedCallback)(RIL_TimedCallback, void *,
                                      const struct timeval *);
static void (*p_onRequestAck)(RIL_Token);

/* Les quatre fonctions que l implementation appelle pour repondre. On ne fait
 * que relayer vers libril : c est exactement ce que fait le rild d AOSP. */
static void env_request_complete(RIL_Token t, RIL_Errno e, void *r, size_t l)
{
    if (p_onRequestComplete) p_onRequestComplete(t, e, r, l);
}

static void env_unsolicited(int unsol, const void *data, size_t len)
{
    if (p_onUnsolicitedResponse) p_onUnsolicitedResponse(unsol, data, len);
}

static void env_timed_callback(RIL_TimedCallback cb, void *param,
                               const struct timeval *rel)
{
    if (p_requestTimedCallback) p_requestTimedCallback(cb, param, rel);
}

static void env_request_ack(RIL_Token t)
{
    if (p_onRequestAck) p_onRequestAck(t);
}

static struct RIL_Env s_env = {
    env_request_complete,
    env_unsolicited,
    env_timed_callback,
    env_request_ack,
};

static void *must_dlopen(const char *path)
{
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) fprintf(stderr, "osmo-rild: dlopen %s: %s\n", path, dlerror());
    return h;
}

int main(int argc, char **argv)
{
    const char *ril_lib = NULL;
    int i, lib_argc = 0;
    char **lib_argv = NULL;
    const RIL_RadioFunctions *funcs;
    const RIL_RadioFunctions *(*rilInit)(const struct RIL_Env *, int, char **);
    void *h_libril, *h_ril;

    /* -l <implementation> [-- <arguments pour elle>] */
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-l") && i + 1 < argc) {
            ril_lib = argv[++i];
        } else if (!strcmp(argv[i], "--")) {
            lib_argc = argc - i;          /* argv[0] compris, cf. plus bas */
            lib_argv = &argv[i];
            lib_argv[0] = argv[0];        /* l implementation attend un argv[0] */
            break;
        }
    }
    if (!ril_lib) {
        fprintf(stderr, "usage: %s -l <bibliotheque RIL> [-- <ses arguments>]\n",
                argv[0]);
        return 2;
    }

    h_libril = must_dlopen(LIBRIL);
    if (!h_libril) return 1;

    p_startEventLoop        = dlsym(h_libril, "RIL_startEventLoop");
    p_register              = dlsym(h_libril, "RIL_register");
    p_onRequestComplete     = dlsym(h_libril, "RIL_onRequestComplete");
    p_onUnsolicitedResponse = dlsym(h_libril, "RIL_onUnsolicitedResponse");
    p_requestTimedCallback  = dlsym(h_libril, "RIL_requestTimedCallback");
    p_onRequestAck          = dlsym(h_libril, "RIL_onRequestAck");
    if (!p_startEventLoop || !p_register) {
        fprintf(stderr, "osmo-rild: %s n a pas RIL_startEventLoop/RIL_register\n",
                LIBRIL);
        return 1;
    }

    h_ril = must_dlopen(ril_lib);
    if (!h_ril) return 1;
    rilInit = dlsym(h_ril, "RIL_Init");
    if (!rilInit) {
        fprintf(stderr, "osmo-rild: %s n a pas RIL_Init\n", ril_lib);
        return 1;
    }

    /* L ordre compte : la boucle d evenements DOIT tourner avant RIL_Init,
     * sinon l implementation poste ses premieres reponses dans le vide. */
    p_startEventLoop();
    funcs = rilInit(&s_env, lib_argc, lib_argv);
    if (!funcs) {
        fprintf(stderr, "osmo-rild: RIL_Init a echoue\n");
        return 1;
    }
    p_register(funcs);

    fprintf(stderr, "osmo-rild: en marche (%s)\n", ril_lib);

    /* [2026-09-06] IL FAUT REJOINDRE LE POOL DE THREADS, PAS DORMIR.
     * libril appelle configureRpcThreadpool(1, callerWillJoin=true) : le
     * « true » signifie que le thread pool ne demarre AUCUN thread de service
     * et compte sur l appelant pour se joindre a lui. Un rild qui se contente
     * de dormir laisse donc un service enregistre mais SANS personne pour
     * repondre - c est exactement ce qu on a observe : lshal montrait
     * « android.hardware.radio@1.1::IRadio/slot1 » declare mais sans serveur,
     * le framework restait bloque (mRadioIndication == NULL) et
     * com.android.phone ne repondait plus. On rejoint donc le pool ; ce thread
     * ne revient jamais, ce qui remplace la boucle d attente. */
    {
        void *h_hidl = dlopen("libhidlbase.so", RTLD_NOW | RTLD_GLOBAL);
        void (*joinRpcThreadpool)(void) = NULL;
        if (h_hidl)
            joinRpcThreadpool = dlsym(h_hidl, "_ZN7android8hardware17joinRpcThreadpoolEv");
        if (joinRpcThreadpool) {
            fprintf(stderr, "osmo-rild: joinRpcThreadpool\n");
            joinRpcThreadpool();
        } else {
            fprintf(stderr, "osmo-rild: joinRpcThreadpool introuvable (%s)\n",
                    h_hidl ? "symbole absent" : dlerror());
        }
    }
    while (1) pause();          /* filet de securite */
    return 0;
}
