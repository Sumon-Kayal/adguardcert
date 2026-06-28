#!/system/bin/sh

exec > /data/local/tmp/adguardcert.log
exec 2>&1

set -x

MODDIR=${0%/*}

set_context() {
    [ "$(getenforce)" = "Enforcing" ] || return 0

    default_selinux_context=u:object_r:system_file:s0
    selinux_context=$(ls -Zd "$1" | awk '{print $1}')

    if [ -n "$selinux_context" ] && [ "$selinux_context" != "?" ]; then
        chcon -R "$selinux_context" "$2"
    else
        chcon -R "$default_selinux_context" "$2"
    fi
}

# Android hashes the subject to get the filename, field order is significant.
# (`openssl x509 -in ... -noout -hash`)
# AdGuard's certificate is "/C=EN/O=AdGuard/CN=AdGuard Personal CA".
# The filename is then <hash>.<n> where <n> is an integer to disambiguate
# different certs with the same hash (e.g. when the same cert is installed repeatedly).
#
# Due to https://github.com/AdguardTeam/AdguardForAndroid/issues/2108
# 1. Retrieve the most recent certificate with our hash from the user store.
#    It is assumed that the last installed AdGuard's cert is the correct one.
# 2. Copy the AdGuard certificate to the system store under the name "<hash>.0".
#    Note that some apps may ignore other certs.
# 3. Remove all certs with our hash from the `cacerts-removed` directory.
#    They get there if a certificate is "disabled" in the security settings.
#    Apps will reject certs that are in the `cacerts-removed`.
AG_CERT_HASH=0f4ed297
AG_CERT_FILE=$(ls /data/misc/user/*/cacerts-added/${AG_CERT_HASH}.* 2>/dev/null \
    | (IFS=.; while read -r left right; do echo $right $left.$right; done) \
    | sort -nr \
    | (read -r left right; echo $right))

if ! [ -e "${AG_CERT_FILE}" ]; then
    echo "AdGuard certificate not found in user store, nothing to do."
    exit 0
fi

rm -f /data/misc/user/*/cacerts-removed/${AG_CERT_HASH}.*

cp -f "${AG_CERT_FILE}" "${MODDIR}/system/etc/security/cacerts/${AG_CERT_HASH}.0"
chown -R 0:0 "${MODDIR}/system/etc/security/cacerts"
set_context /system/etc/security/cacerts "${MODDIR}/system/etc/security/cacerts"

# ─── Android 14+ support ──────────────────────────────────────────────────────
# Magisk ignores /apex for module file injections, so we use a tmpfs bind-mount.
#
#  Android 14 : /apex/com.android.conscrypt/cacerts moved out of Magisk scope.
#               Requires bind-mount into init (pid 1), zygote, and zygote64.
#  Android 15+: system_server may start independently before zygote; must also
#               receive the propagated mount.
#  Android 16+: Versioned APEX paths (/apex/com.android.conscrypt@<ver>/cacerts)
#               may be accessed directly by some processes in their mount
#               namespaces, requiring an explicit bind-mount on each path.
# ──────────────────────────────────────────────────────────────────────────────
APEX_CACERTS=/apex/com.android.conscrypt/cacerts

if [ -d "${APEX_CACERTS}" ]; then
    AG_TMP=/data/local/tmp/adg-ca-copy

    # Clone the live cert directory into a tmpfs overlay.
    rm -rf "${AG_TMP}"
    mkdir -p "${AG_TMP}"
    mount -t tmpfs tmpfs "${AG_TMP}"
    cp -f "${APEX_CACERTS}/"* "${AG_TMP}/"

    # Inject AdGuard's cert into the overlay.
    cp -f "${AG_CERT_FILE}" "${AG_TMP}/${AG_CERT_HASH}.0"
    chown -R 0:0 "${AG_TMP}"
    set_context "${APEX_CACERTS}" "${AG_TMP}"

    CERTS_NUM="$(ls -1 "${AG_TMP}" | wc -l)"
    if [ "${CERTS_NUM}" -gt 10 ]; then
        # Bind-mount the overlay over the APEX cert dir in the root namespace.
        mount --bind "${AG_TMP}" "${APEX_CACERTS}"

        # Propagate the mount into every relevant namespace:
        #   pid 1         – init  (Android 14+)
        #   zygote/64     – Android 14+
        #   system_server – Android 15+ (may initialise TLS before zygote)
        for pid in 1 $(pgrep zygote) $(pgrep zygote64) $(pgrep system_server); do
            [ -f "/proc/${pid}/ns/mnt" ] || continue
            nsenter --mount="/proc/${pid}/ns/mnt" -- \
                /bin/mount --bind "${AG_TMP}" "${APEX_CACERTS}" \
                || echo "nsenter: propagation failed for pid ${pid}, skipping."
        done

        # Android 16+: also mount into versioned APEX paths that exist alongside
        # the canonical symlink, as some processes resolve them directly.
        for versioned in /apex/com.android.conscrypt@*/cacerts; do
            [ -d "${versioned}" ] || continue
            # Avoid double-mounting if the versioned path is the same inode.
            [ "${versioned}" = "${APEX_CACERTS}" ] && continue
            mount --bind "${AG_TMP}" "${versioned}" \
                || echo "versioned APEX mount skipped: ${versioned}"
        done
    else
        echo "Safety check failed: only ${CERTS_NUM} cert(s) in tmpfs — aborting APEX injection."
    fi

    umount "${AG_TMP}"
    rmdir "${AG_TMP}"
fi
