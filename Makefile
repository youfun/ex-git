# Host build for the libgit2 NIF. Android/iOS packaging lives under native/.
# Invoked by elixir_make; do not assume this Makefile is run by hand.

ERL_CFLAGS ?= -I"$(ERTS_INCLUDE_DIR)"
ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval "io:format(\"~s/erts-~s/include/\", [code:root_dir(), erlang:system_info(version)]), halt().")

PRIV_DIR = $(if $(MIX_APP_PATH),$(MIX_APP_PATH)/priv,priv)
NIF_NAME = ex_git_nif
NIF_SO = $(PRIV_DIR)/$(NIF_NAME).so
SRC = c_src/ex_git_nif.c

UNAME_SYS := $(shell uname -s)

ifeq ($(LIBGIT2_DIR),)
  LIBGIT2_DIR := $(shell brew --prefix libgit2 2>/dev/null)
endif
ifeq ($(LIBGIT2_DIR),)
  LIBGIT2_DIR := /usr/local
endif

CFLAGS ?= -O3 -std=c11 -Wall -Wextra -Wmissing-prototypes -Wno-missing-field-initializers -fPIC
CFLAGS += -I"$(LIBGIT2_DIR)/include" $(ERL_CFLAGS)
LDFLAGS += -L"$(LIBGIT2_DIR)/lib" -lgit2

ifeq ($(UNAME_SYS), Darwin)
  SDKROOT ?= $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
  CFLAGS += -fvisibility=hidden
  ifneq ($(SDKROOT),)
    CFLAGS += -isysroot "$(SDKROOT)"
    LDFLAGS += -isysroot "$(SDKROOT)"
  endif
  LDFLAGS += -shared -undefined dynamic_lookup -Wl,-rpath,$(LIBGIT2_DIR)/lib
else
  LDFLAGS += -shared
endif

.PHONY: all clean

all: $(NIF_SO)

$(NIF_SO): $(SRC) | $(PRIV_DIR)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)

$(PRIV_DIR):
	mkdir -p "$@"

clean:
	rm -f "$(NIF_SO)"
