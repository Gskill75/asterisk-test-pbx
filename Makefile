# Test PBX, see README.md

-include .env

ASTERISK_VERSION ?= 22.11.0

# Works with docker too: make CTR=docker ...
CTR       ?= podman
COMPOSE   ?= $(CTR) compose
PBX_IMAGE ?= localhost/asterisk-test-pbx
CAP_IMAGE ?= localhost/asterisk-test-pbx-capture
PBX_NETWORK ?= $(if $(filter docker,$(CTR)),bridge,pasta)
export PBX_IMAGE PBX_NETWORK

SRV_NAME ?= pbx
CNT_CLI  ?= asterisk -rvvv

# Address used by the phones to reach the PBX, the host itself by default.
# Use the interface of the default route, the host might have several.
HOST_IF  ?= $(shell route -n get default 2>/dev/null | awk '/interface:/{print $$2}')
HOST_IP  ?= $(shell ipconfig getifaddr $(HOST_IF) 2>/dev/null || hostname -I 2>/dev/null | cut -d' ' -f1)

# Podman publishes ports through gvproxy, which the macOS firewall may block.
GVPROXY  ?= $(realpath $(dir $(realpath $(shell command -v $(CTR))))../libexec/podman/gvproxy)
FW       ?= /usr/libexec/ApplicationFirewall/socketfilterfw

# Pre-answer music, 8 kHz mono 16 bit wav: make preanswer SRC=music.mp3,
# a demo melody otherwise.
PRE_FILE  ?= sounds/predecroche.wav
PRE_NOTES ?= C4 E4 G4 C5 G4 E4

pw = $$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16)

.PHONY: init image build preanswer up down reset destroy ps logs sh cli \
	endpoints contacts registrations channels trace history_on history \
	captures accounts host_ip firewall firewall_allow test test_183 test_180 clean

init: .env image $(PRE_FILE) up

.env:
	@echo "Creating $@ from .env.example, edit it to configure the SIP trunk."
	@sed -e "s/^\(SIP_PASSWORD_10[0-2]\)=$$/\1=$(pw)/" .env.example > $@

# Build the images when missing, build rebuilds them.
image:
	@$(CTR) image inspect $(PBX_IMAGE) >/dev/null 2>&1 || $(MAKE) build

build:
	$(CTR) build --build-arg ASTERISK_VERSION=$(ASTERISK_VERSION) \
	-t $(PBX_IMAGE) -t $(PBX_IMAGE):$(ASTERISK_VERSION) .
	$(CTR) build -t $(CAP_IMAGE) -f capture/Containerfile capture

$(PRE_FILE): | image
	$(MAKE) preanswer

preanswer:
ifdef SRC
	$(CTR) run --rm --entrypoint sox -v "$(abspath $(dir $(SRC)))":/in:ro \
	-v ./$(dir $(PRE_FILE)):/out $(PBX_IMAGE) \
	"/in/$(notdir $(SRC))" -r 8000 -c 1 -b 16 /out/$(notdir $(PRE_FILE))
else
	$(CTR) run --rm --entrypoint sh -v ./$(dir $(PRE_FILE)):/out $(PBX_IMAGE) -c '\
	for n in $(PRE_NOTES); do sox -n -r 8000 -c 1 -b 16 /tmp/$$n.wav \
	synth 0.35 pluck $$n fade 0 0.35 0.1; done; \
	sox $(addprefix /tmp/,$(addsuffix .wav,$(PRE_NOTES))) \
	/out/$(notdir $(PRE_FILE)) repeat 2 gain -3'
endif

up: | .env
	mkdir -p captures
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

# The capture container shares the PBX network namespace, so recreate both.
reset: down up

destroy: down
	rm -rf captures

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs $(SRV_NAME)

sh:
	$(COMPOSE) exec $(SRV_NAME) bash

cli:
	$(COMPOSE) exec $(SRV_NAME) $(CNT_CLI)

endpoints contacts registrations channels:
	$(COMPOSE) exec $(SRV_NAME) asterisk -rx 'pjsip show $@'

# Live console with SIP messages, quit with Ctrl-C
trace:
	$(COMPOSE) exec $(SRV_NAME) asterisk -rx 'pjsip set logger on'
	$(COMPOSE) exec $(SRV_NAME) $(CNT_CLI)

# SIP messages exchanged since: make history_on
history_on:
	$(COMPOSE) exec $(SRV_NAME) asterisk -rx 'pjsip set history on'

history:
	$(COMPOSE) exec $(SRV_NAME) asterisk -rx 'pjsip show history'

captures:
	open http://$(or $(CAPTURE_BIND:0.0.0.0=127.0.0.1),127.0.0.1):8080 2>/dev/null || \
	echo http://$(or $(CAPTURE_BIND:0.0.0.0=127.0.0.1),127.0.0.1):8080

accounts:
	@echo "Server: $(PBX_EXTERNAL_IP):5060 (udp/tcp)"
	@echo "100 / $(SIP_PASSWORD_100)"
	@echo "101 / $(SIP_PASSWORD_101)"
	@echo "102 / $(SIP_PASSWORD_102)"

host_ip:
	@echo $(HOST_IP)

firewall:
	$(FW) --getappblocked $(GVPROXY)

firewall_allow:
	sudo $(FW) --unblockapp $(GVPROXY)

# Pre-answer test bench, see README.md: test_183 with the pre-answer music
# (PBX_PREANSWER=yes), test_180 without it, test both.
TEST_COMPOSE ?= $(COMPOSE) -f test/compose.yml

test: test_183 test_180

test_183: TEST_PREANSWER = yes
test_180: TEST_PREANSWER = no
test_183 test_180: image $(PRE_FILE)
	-$(TEST_COMPOSE) down -t 1 >/dev/null 2>&1
	PBX_PREANSWER=$(TEST_PREANSWER) $(TEST_COMPOSE) up -d pbx
	@for i in $$(seq 30); do $(CTR) exec asterisk-test-pbx-test \
	asterisk -rx 'core waitfullybooted' >/dev/null 2>&1 && break; sleep 1; done
	PBX_PREANSWER=$(TEST_PREANSWER) $(TEST_COMPOSE) run --rm sipp; \
	rc=$$?; $(TEST_COMPOSE) down -t 1 >/dev/null 2>&1; exit $$rc

clean: destroy
	-$(TEST_COMPOSE) down -t 1
	rm -f test/out/*.pcap test/out/*.log
