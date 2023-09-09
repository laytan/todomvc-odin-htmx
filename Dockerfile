FROM alpine:latest

WORKDIR /odin

ENV PATH "$PATH:/usr/lib/llvm14/bin:/odin"

RUN apk add --no-cache git bash make clang14 llvm14-dev musl-dev linux-headers

RUN git clone --depth=1 https://github.com/odin-lang/Odin . && \
	LLVM_CONFIG=llvm14-config make

WORKDIR /app

COPY . .

RUN odin build vendor/temple/cli -out:./temple && ./temple . vendor/temple
RUN odin build . -o:speed -disable-assert -no-bounds-check -out:todomvc -extra-linker-flags:"-static"

FROM scratch

COPY --from=0 /app/todomvc /bin/todomvc

CMD ["/bin/todomvc"]
