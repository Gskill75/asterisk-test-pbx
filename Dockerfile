# Asterisk built from source, see README.md.
#
#   podman build --build-arg ASTERISK_VERSION=22.11.0 -t asterisk-test-pbx .
#
# The configuration is not part of the image layout Asterisk expects: it is
# copied from /config to /etc/asterisk by the entrypoint, at every start, so
# that ./config can be mounted and edited without rebuilding.

ARG DEBIAN_RELEASE=trixie

#
# build
#

FROM docker.io/library/debian:${DEBIAN_RELEASE}-slim AS build
ARG ASTERISK_VERSION=22.11.0

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
	build-essential bzip2 ca-certificates curl file patch pkg-config \
	libcurl4-openssl-dev libedit-dev libjansson-dev libsqlite3-dev \
	libsrtp2-dev libssl-dev libxml2-dev uuid-dev

WORKDIR /usr/src/asterisk
RUN curl -fsSL https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-$ASTERISK_VERSION.tar.gz \
	| tar xz --strip-components=1

# Portable binaries (no -march=native), bundled pjproject, english core sounds
# and the default music on hold. /var/run is a symlink to /run in the runtime
# image, which docker refuses to copy a directory onto.
RUN ./configure --prefix=/usr --libdir=/usr/lib --with-pjproject-bundled \
	&& make menuselect.makeopts \
	&& menuselect/menuselect --disable BUILD_NATIVE \
	--enable CORE-SOUNDS-EN-GSM --enable MOH-OPSOUND-WAV menuselect.makeopts \
	&& make -j$(nproc) \
	&& make install DESTDIR=/staging \
	&& rm -rf /staging/usr/include \
	&& mkdir -p /staging/run \
	&& mv /staging/var/run/asterisk /staging/run/ \
	&& rmdir /staging/var/run

# Debian packages providing the shared libraries Asterisk links to.
RUN find /staging -type f \( -name '*.so*' -o -path '*/sbin/*' \) \
	-exec ldd {} + 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3}' \
	| sort -u | while read -r lib; do \
		dpkg -S "$lib" 2>/dev/null || dpkg -S "$(realpath "$lib")" 2>/dev/null; \
	done | cut -d: -f1 | sort -u > /staging/runtime-packages \
	&& cat /staging/runtime-packages

#
# runtime
#

FROM docker.io/library/debian:${DEBIAN_RELEASE}-slim
ARG ASTERISK_VERSION=22.11.0
LABEL org.opencontainers.image.title="asterisk-test-pbx" \
	org.opencontainers.image.description="Asterisk $ASTERISK_VERSION test PBX" \
	org.opencontainers.image.version="$ASTERISK_VERSION"

COPY --from=build /staging/ /

# curl detects the public address, sox converts or synthesizes the pre-answer
# music (make preanswer), tzdata is for the speaking clock (603).
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
	ca-certificates curl sox libsox-fmt-mp3 tzdata $(cat /runtime-packages) \
	&& rm -rf /var/lib/apt/lists/* /runtime-packages \
	&& ldconfig \
	&& useradd --system --home-dir /var/lib/asterisk --shell /usr/sbin/nologin asterisk \
	&& mkdir -p /etc/asterisk /var/lib/asterisk/sounds/custom \
	&& chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk \
	/var/log/asterisk /var/spool/asterisk /var/run/asterisk \
	&& asterisk -V

COPY config/ /config/
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 5060/udp 5060/tcp 10000-10099/udp
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
	CMD asterisk -rx 'core show uptime' >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
