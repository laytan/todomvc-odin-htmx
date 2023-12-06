package main

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:net"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:os"
import "core:io"

import "vendor/http"
import bt "vendor/obacktracing"

// This comment is here to keep track of any issues, small or large I came across making this example.
// And if they are fixed.
//
// Breaking problems:
// [x] multiple templates should emit `else when`
// [x] every few requests the method is right after the title of the prev request
//
// [ ] an inline if cuts of the i of li in exmple: `<li {% if this.completed %}class="completed"{% end %}>`
//     can't replicate anymore, wtf?
//
// Usability problems:
// [x] responding twice is hard to catch (easy bug, need some assertion or error)
// [ ] Getting the body is very verbose
//   [ ] add automatic response options if type doesn't match
//   [ ] req and res in the same struct passed to the handler maybe
// [ ] There is no easy way to keep state or middleware-added parameters
// [x] something like `http.respond(res, .Ok, .Html)` would be good
// [x] parsing cookies out of a `Cookie: x=y; b=a;` header
// [ ] validation is painful
// [ ] good to have an official session middleware
// [ ] can we do something for csrf
// [x] very easy to mistakenly add a header to the request headers, should that even be allowed?
// [ ] helper stuff like `temple.into_buffer`, `temple.into_builder` which resizes and writes the template
// [ ] have to fully specify status/content type namespace, is this an Odin "bug" we can fix?
// [x] for more performance, we should say, write your headers and status code, then write your body,
//     this way we make the Response.body buffer the actual buffer that gets send, instead of more copying.
// [x] net.IP4_Any should be the default address
// [x] lots of logs, new connection should be a debug log

Todo :: struct {
	id:        int,
	title:     string,
	completed: bool,
}

INDEX: string

@(init)
init :: proc() {
	INDEX = os.lookup_env("INDEX") or_else "http://localhost:8080"
}

main :: proc() {
	context.logger = log.create_console_logger(
		.Info,
		log.Options{.Level, .Time, .Short_File_Path, .Line, .Terminal_Color, .Thread_Id},
	)

    bt.register_segfault_handler()
    context.assertion_failure_proc = bt.assertion_failure_proc

	server: http.Server
	r: http.Router
	http.router_init(&r)

	// Health check.
	http.route_get(&r, "/health", http.handler(proc(_: ^http.Request, r: ^http.Response) {
		http.respond(r, http.Status.OK)
	}))

	// Listing, with filtering.
	http.route_get(&r,    "/",                http.handler(handler_index))
	http.route_get(&r,    "/active",          http.handler(handler_index))
	http.route_get(&r,    "/completed",       http.handler(handler_index))

	// Deletes all completed.
	http.route_delete(&r, "/todos/completed", http.handler(handler_clean))

	// Toggles all.
	http.route_post(&r,   "/todos/toggle",    http.handler(handler_toggle))

	// Creates one.
	http.route_post(&r,   "/todos",           http.handler(handler_create_todo))

	// Changes or deletes one.
	http.route_patch(&r,  "/todos/(%d+)",     http.handler(handler_todo_patch))
	http.route_delete(&r, "/todos/(%d+)",     http.handler(handler_delete_todo))

	// Static files, easiest is this:
	// http.route_get(&r, ".*", http.handler(proc(req: ^http.Request, res: ^http.Response) {
	// 	http.respond_dir(res, "/", "static", req.url.path)
	// }))

	// Faster and more portable (files are in the executable) is this:
	http.route_get(&r, "/favicon%.ico", http.handler(proc(_: ^http.Request, r: ^http.Response) {
		http.respond_file_content(r, "favicon.ico", #load("static/favicon.ico"))
	}))
	http.route_get(&r, "/htmx@1%.%9%.5%.min%.js", http.handler(proc(_: ^http.Request, r: ^http.Response) {
		http.respond_file_content(r, "htmx@1.9.5.min.js", #load("static/htmx@1.9.5.min.js"))
	}))
	http.route_get(&r, "/todomvc%-app%-css@2%.4%.2%-index%.css", http.handler(proc(_: ^http.Request, r: ^http.Response) {
		http.respond_file_content(r, "todomvc-app-css@2.4.2-index.css", #load("static/todomvc-app-css@2.4.2-index.css"))
	}))

	routed    := http.router_handler(&r)
	sessioned := http.middleware_proc(&routed, session_middleware)
	logged    := http.middleware_proc(
		&sessioned,
		proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
			log.infof(
				"%s %q, from %q via %q",
				http.method_string(req.line.?.method),
				req.url.raw,
				http.headers_get_unsafe(req.headers, "user-agent"),
				http.headers_get_unsafe(req.headers, "referer"),
			)

			h.next.?.handle(h.next.?, req, res)
		},
	)

	log.info("Listening on port 8080")

	err := http.listen_and_serve(&server, logged, net.Endpoint{
		address = net.IP4_Any,
		port    = 8080,
	})
	fmt.assertf(err == nil, "Server error: %v", err)
}

Page :: enum {
	All,
	Active,
	Completed,
}

page_parse :: proc(val: string) -> Page {
	switch val {
	case "active":    return .Active
	case "completed": return .Completed
	case:             return .All
	}
}

page_from_path :: proc(req: string) -> Page {
	page := req[strings.last_index_byte(req, '/') + 1:]
	return page_parse(page)
}

handler_index :: proc(req: ^http.Request, res: ^http.Response) {
	session := session_get(req)

	is_htmx := http.headers_has_unsafe(req.headers, "hx-request")
	respond_list(res, !is_htmx, session, page_from_path(req.url.path))
}

handler_create_todo :: proc(req: ^http.Request, res: ^http.Response) {
	context.user_ptr = req
    // TODO: max length should be later in the args.
	http.body(req, -1, res, proc(res: rawptr, raw_body: http.Body, err: http.Body_Error) {
		req := cast(^http.Request)context.user_ptr
		res := cast(^http.Response)res

        if err != nil {
			log.warnf("Body error: %v", err)
			http.respond(res, http.body_error_status(err))
            return
        }

        body, ok := http.body_url_encoded(raw_body)
        if !ok {
			log.warnf("Invalid URL encoded body: %q", raw_body)
			http.respond(res, http.Status.Unprocessable_Content)
            return
        }

        title := body["title"]
        if len(title) == 0 {
            http.respond(res, http.Status.Unprocessable_Content)
            return
        }

        @(static)
        _id: int
        tid := sync.atomic_add(&_id, 1)

        session := session_get(req)

        todo := new(Todo)
        todo.id = tid
        todo.title = strings.clone(title)

        append(&session.list, todo)

        rw: http.Response_Writer
        buf: [512]byte
        w := http.response_writer_init(&rw, res, buf[:])

        // TODO: default to 200 status if a route matched.
        http.response_status(res, .OK)
        http.headers_set_content_type(&res.headers, http.mime_to_content_type(.Html))

        // Don't want to show the item when we are on the /completed page.
        switch page_from_path(http.headers_get_unsafe(req.headers, "hx-current-url")) {
        case .All, .Active:
            // TODO: `http.response_writer_reserve`.
            bytes.buffer_grow(&res._buf, tmpl_todo.approx_bytes + tmpl_count.approx_bytes)

            if _, terr := tmpl_todo.with(w, todo);            terr != nil do log.error(terr)
            if _, cerr := tmpl_count.with(w, count(session)); cerr != nil do log.error(cerr)
            if werr    := io.close(w);                        werr != nil do log.error(werr)
            return

        case .Completed:
            // Only render the footer/count changes.

            // TODO: `http.response_writer_reserve`.
            bytes.buffer_grow(&res._buf, tmpl_count.approx_bytes)

            if _, cerr := tmpl_count.with(w, count(session)); cerr != nil do log.error(cerr)
            if werr    := io.close(w);                        werr != nil do log.error(werr)
            return
        }
	})
}

handler_todo_patch :: proc(req: ^http.Request, res: ^http.Response) {
	context.user_ptr = req
	http.body(req, -1, res, proc(res: rawptr, raw_body: http.Body, err: http.Body_Error) {
		req := cast(^http.Request)context.user_ptr
		res := cast(^http.Response)res

        if err != nil {
            log.warnf("Body error: %v", err)
            http.respond(res, http.body_error_status(err))
            return
        }

        body, bok := http.body_url_encoded(raw_body)
        if !bok {
            log.warnf("Invalid URL encoded body: %q", raw_body)
            http.respond(res, http.Status.Unprocessable_Content)
            return
        }

        int_id, iok := strconv.parse_i64_of_base(req.url_params[0], 10)
        if !iok || int_id < 0 {
            http.respond(res, http.Status.Unprocessable_Content)
            return
        }

        title, has_title := body["title"]
        if has_title && len(title) == 0 {
            http.respond(res, http.Status.Unprocessable_Content)
            return
        }

        completed := (body["completed"] or_else "off") == "on"

        session := session_get(req)
        item, found := session_get_todo(session, int(int_id)).?
        if !found {
            http.respond(res, http.Status.Not_Found)
            return
        }
        todo := item.todo

        { // Updating.

            // Reactivated the item.
            if todo.completed && !completed {
                session.completed -= 1
            }

            // Completed the item.
            if !todo.completed && completed {
                session.completed += 1
            }

            todo.completed = completed

            if has_title do todo.title = strings.clone(title)
        }

        { // Rendering.
            // TODO: default to 200 status if a route matched.
            http.response_status(res, .OK)
            http.headers_set_content_type(&res.headers, http.mime_to_content_type(.Html))

            // Only show the new item if it needs to be on the current page.
            show_item: bool
            switch page_from_path(http.headers_get_unsafe(req.headers, "hx-current-url")) {
            case .All:       show_item = true
            case .Completed: show_item = todo.completed
            case .Active:    show_item = !todo.completed
            }

            rw: http.Response_Writer
            buf: [512]byte
            w := http.response_writer_init(&rw, res, buf[:])

            // Grow the result buffer to the approximation of what we are going to render,
            // this is a performance optimization and not mandatory.
            approx := tmpl_count.approx_bytes
            if show_item do approx += tmpl_todo.approx_bytes
            bytes.buffer_grow(&res._buf, approx)

            // Out of bounds update the footer.
            if _, cerr := tmpl_count.with(w, count(session)); cerr != nil do log.error(cerr)
            if show_item {
                if _, terr := tmpl_todo.with(w, todo);        terr != nil do log.error(terr)
            }
            if werr := io.close(w);                           werr != nil do log.error(werr)
        }
        return
    })
}

handler_delete_todo :: proc(req: ^http.Request, res: ^http.Response) {
	int_id, ok := strconv.parse_i64_of_base(req.url_params[0], 10)
	if !ok || int_id < 0 {
		http.respond(res, http.Status.Unprocessable_Content)
		return
	}

	session := session_get(req)
	if item, found := session_get_todo(session, int(int_id)).?; found {
		if item.todo.completed {
			session.completed -= 1
		}

		delete(item.todo.title)
		unordered_remove(&session.list, item.index)
		free(item.todo)
	}

    rw: http.Response_Writer
    buf: [512]byte
    w := http.response_writer_init(&rw, res, buf[:])

    http.response_status(res, .OK)
    http.headers_set_content_type(&res.headers, http.mime_to_content_type(.Html))

	// Send updated count.
	bytes.buffer_grow(&res._buf, tmpl_count.approx_bytes)
	if _, err := tmpl_count.with(w, count(session)); err  != nil do log.error(err)
    if werr   := io.close(w);                        werr != nil do log.error(werr)
}

handler_toggle :: proc(req: ^http.Request, res: ^http.Response) {
	session := session_get(req)

	all_completed := len(session.list) == session.completed
	for todo in session.list {
        switch {
        case  todo.completed &&  all_completed: session.completed -= 1
        case !todo.completed && !all_completed: session.completed += 1
        }
		todo.completed = !all_completed
	}

	respond_list(res, false, session, page_from_path(http.headers_get_unsafe(req.headers, "hx-current-url")))
}

handler_clean :: proc(req: ^http.Request, res: ^http.Response) {
	session := session_get(req)

	for todo, i in session.list {
		if todo.completed {
			session.completed -= 1
			delete(todo.title)
			unordered_remove(&session.list, i)
			free(todo)
		}
	}

	respond_list(res, false, session, page_from_path(http.headers_get_unsafe(req.headers, "hx-current-url")))
}

respond_list :: proc(res: ^http.Response, full_page: bool, session: ^Session, page: Page) {
	l: List
	l.count     = count(session)
	l.count.oob = false
	l.page      = page
	l.todos     = session.list[:]

	slice.sort_by(session.list[:], proc(a, b: ^Todo) -> bool {return a.id > b.id})

	// Apply filtering.
	if page == .Active || page == .Completed {
		n := l.count.completed if page == .Completed else l.count.active
		filtered := make([dynamic]^Todo, 0, n, context.temp_allocator)
		defer l.todos = filtered[:]

		for todo in session.list {
			if todo.completed && page == .Completed {
				append(&filtered, todo)
			} else if !todo.completed && page == .Active {
				append(&filtered, todo)
			}
		}
	}

    rw: http.Response_Writer
    buf: [512]byte
    w := http.response_writer_init(&rw, res, buf[:])
    // TODO: response_writer_destroy that cleans up/responds.

    http.response_status(res, .OK)
    http.headers_set_content_type(&res.headers, http.mime_to_content_type(.Html))

	tmpl := tmpl_index if full_page else tmpl_list
	bytes.buffer_grow(&res._buf, tmpl.approx_bytes)
	if _, err := tmpl.with(w, l); err  != nil do log.error(err)
    if werr   := io.close(w);     werr != nil do log.error(werr)
}
