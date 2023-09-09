package main

import "core:path/filepath"
import "core:fmt"
import "core:os"

main :: proc() {
	filepath.walk(
	".",
	proc(info: os.File_Info, in_err: os.Errno, user_data: rawptr) -> (err: os.Errno, skip_dir: bool) {
		// We only get here once, with the root directory, even though there are more files.

		assert(err == os.ERROR_NONE)

		fmt.println(info.fullpath) // /app (the root)
		fmt.println(info.is_dir)   // false (this is certainly a directory)
		return
	}, nil)
}
