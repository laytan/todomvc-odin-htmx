FROM alpine:latest

WORKDIR /odin

ENV PATH "$PATH:/usr/lib/llvm14/bin:/odin"

RUN apk add --no-cache git bash make clang14 llvm14-dev musl-dev linux-headers

RUN git clone --depth=1 https://github.com/laytan/Odin --branch=fix-stat-struct-layout-linux-arm64 . && \
	LLVM_CONFIG=llvm14-config make

WORKDIR /execinfo

# Libexecinfo because musl/alpine doesn't provide the `backtrace` libc API out of the box.
RUN git clone https://github.com/ronchaine/libexecinfo.git . && \
	make install

WORKDIR /app

COPY . .

RUN odin build vendor/temple/cli -out:./temple && ./temple . vendor/temple
# RUN odin build . -o:speed -disable-assert -no-bounds-check -debug -out:todomvc -extra-linker-flags:"-static"
RUN odin build . -o:speed -debug -out:todomvc -extra-linker-flags:"-lexecinfo -static"

ENV INDEX=

EXPOSE 8080

CMD ["/app/todomvc"]
