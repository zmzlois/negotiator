CXX ?= c++
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra -pedantic
LDFLAGS ?=
TARGET ?= silero_vad_eot
USE_ONNXRUNTIME ?= 1
ONNXRUNTIME_DIR ?= $(shell brew --prefix onnxruntime 2>/dev/null)

ifeq ($(USE_ONNXRUNTIME),1)
CXXFLAGS += -DUSE_ONNXRUNTIME -I$(ONNXRUNTIME_DIR)/include/onnxruntime
LDFLAGS += -L$(ONNXRUNTIME_DIR)/lib -lonnxruntime -Wl,-rpath,$(ONNXRUNTIME_DIR)/lib
endif

.PHONY: all clean

all: $(TARGET)

$(TARGET): silero_vad_eot.cpp
	$(CXX) $(CXXFLAGS) $< $(LDFLAGS) -o $@

clean:
	rm -f $(TARGET)
