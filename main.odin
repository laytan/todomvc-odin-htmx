package main

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"

import "vendor/http"

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
// [ ] responding twice is hard to catch (easy bug, need some assertion or error)
// [ ] Getting the body is very verbose
//   [ ] add automatic response options if type doesn't match
//   [ ] req and res in the same struct passed to the handler maybe
// [ ] There is no easy way to keep state or middleware-added parameters
// [x] something like `http.respond(res, .Ok, .Html)` would be good
// [ ] parsing cookies out of a `Cookie: x=y; b=a;` header
// [ ] validation is painful
// [ ] good to have an official session middleware
// [ ] can we do something for csrf
// [ ] very easy to mistakenly add a header to the request headers, should that even be allowed?
// [ ] helper stuff like `temple.into_buffer`, `temple.into_builder` which resizes and writes the template
// [ ] have to fully specify status/content type namespace, is this an Odin "bug" we can fix?
// [ ] for more performance, we should say, write your headers and status code, then write your body,
//     this way we make the Response.body buffer the actual buffer that gets send, instead of more copying.

Todo :: struct {
	id:        int,
	title:     string,
	completed: bool,
}

INDEX :: "http://localhost:8080"

main :: proc() {
	context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Info)

	server: http.Server
	r: http.Router
	http.router_init(&r)

    // Listing, with filtering.
	http.route_get(   &r, "/",                 http.handler(handler_index))
	http.route_get(   &r, "/active",           http.handler(handler_index))
	http.route_get(   &r, "/completed",        http.handler(handler_index))

    // Deletes all completed.
	http.route_delete(&r, "/todos/completed",  http.handler(handler_clean))

    // Toggles all.
	http.route_post(  &r, "/todos/toggle",     http.handler(handler_toggle))

    // Creates one.
	http.route_post(  &r, "/todos",            http.handler(handler_create_todo))

    // Changes or deletes one.
	http.route_patch( &r, "/todos/(%d+)",      http.handler(handler_todo_patch))
	http.route_delete(&r, "/todos/(%d+)",      http.handler(handler_delete_todo))

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

	err := http.listen_and_serve(&server, sessioned)
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
	page := req[strings.last_index_byte(req, '/')+1:]
    return page_parse(page)
}

handler_index :: proc(req: ^http.Request, res: ^http.Response) {
    session := session_get(req)

    is_htmx := "hx-request" in req.headers
	respond_list(res, !is_htmx, session, page_from_path(req.url.path))
}

handler_create_todo :: proc(req: ^http.Request, res: ^http.Response) {
	context.user_ptr = req
	http.request_body(req, proc(body: http.Body_Type, _: bool, res: rawptr) {
		req := cast(^http.Request)context.user_ptr
		res := cast(^http.Response)res
		#partial switch b in body {
		case http.Body_Error:
			log.warnf("Body error: %v", b)
			http.respond(res, http.body_error_status(b))
			return

		case http.Body_Url_Encoded:
			title, has_title := b["title"]
			if !has_title || len(title) == 0 {
				http.respond(res, http.Status.Unprocessable_Content)
				return
			}

			@static _id: int
			tid := sync.atomic_add(&_id, 1)

			session := session_get(req)

			todo      := new(Todo)
            todo.id    = tid
            todo.title = strings.clone(title)

			append(&session.list, todo)

            // Don't want to show the item when we are on the /completed page.
			switch page_from_path(req.headers["hx-current-url"]) {
			case .All, .Active:
				bytes.buffer_grow(&res.body, tmpl_todo.approx_bytes + tmpl_count.approx_bytes)
                w := bytes.buffer_to_stream(&res.body)

				tmpl_todo.with(w, todo)
                tmpl_count.with(w, count(session))

				http.respond(res, http.Status.OK, http.Mime_Type.Html)
				return

			case .Completed:
				// Only render the footer/count changes.
				bytes.buffer_grow(&res.body, tmpl_count.approx_bytes)
                tmpl_count.with(bytes.buffer_to_stream(&res.body), count(session))

				http.respond(res, http.Status.OK, http.Mime_Type.Html)
				return
			}

		case:
			log.warnf("Invalid body type %T", b)
			http.respond(res, http.Status.Unprocessable_Content)
			return
		}
	}, user_data = res)
}

handler_todo_patch :: proc(req: ^http.Request, res: ^http.Response) {
	context.user_ptr = req
	http.request_body(req, proc(body: http.Body_Type, _: bool, res: rawptr) {
		req := cast(^http.Request)context.user_ptr
		res := cast(^http.Response)res
		switch b in body {
		case http.Body_Error:
			log.warnf("Body error: %v", b)
			http.respond(res, http.body_error_status(b))
			return

		case http.Body_Plain:
			log.warnf("Invalid body type %T", b)
			http.respond(res, http.Status.Unprocessable_Content)
			return

		case http.Body_Url_Encoded:
			int_id, ok := strconv.parse_i64_of_base(req.url_params[0], 10)
			if !ok || int_id < 0 {
				http.respond(res, http.Status.Unprocessable_Content)
				return
			}

			title, has_title := b["title"]
			if has_title && len(title) == 0 {
				http.respond(res, http.Status.Unprocessable_Content)
				return
			}

			completed := (b["completed"] or_else "off") == "on"

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

				// Only show the new item if it needs to be on the current page.
				show_item: bool
				switch page_from_path(req.headers["hx-current-url"]) {
				case .All:       show_item = true
				case .Completed: show_item = todo.completed
				case .Active:    show_item = !todo.completed
				}

				// Grow the result buffer to the approximation of what we are going to render,
				// this is a performance optimization and not mandatory.
				approx := tmpl_count.approx_bytes
				if show_item do approx += tmpl_todo.approx_bytes
				bytes.buffer_grow(&res.body, approx)

				w := bytes.buffer_to_stream(&res.body)

				// Out of bounds update the footer.
				tmpl_count.with(w, count(session))

				if show_item do tmpl_todo.with(w, todo)
			}

			http.respond(res, http.Status.OK, http.Mime_Type.Html)
			return
		}
	}, user_data = res)
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

	// Send updated count.
	bytes.buffer_grow(&res.body, tmpl_count.approx_bytes)
	tmpl_count.with(bytes.buffer_to_stream(&res.body), count(session))

	http.respond(res, http.Status.OK, http.Mime_Type.Html)
}

handler_toggle :: proc(req: ^http.Request, res: ^http.Response) {
	session := session_get(req)

	all_completed := true
	for todo in session.list {
		if !todo.completed {
			all_completed = false
			break
		}
	}

	for todo in session.list {
		todo.completed = !all_completed
	}

	respond_list(res, false, session, page_from_path(req.headers["hx-current-url"]))
}

handler_clean :: proc(req: ^http.Request, res: ^http.Response) {
	session := session_get(req)

	for todo, i in session.list {
		if todo.completed {
			delete(todo.title)
			unordered_remove(&session.list, i)
			free(todo)
		}
	}

	respond_list(res, false, session, page_from_path(req.headers["hx-current-url"]))
}

respond_list :: proc(res: ^http.Response, full_page: bool, session: ^Session, page: Page) {
    l: List
	l.count     = count(session)
	l.count.oob = false
	l.page  = page
	l.todos = session.list[:]

	slice.sort_by(session.list[:], proc(a, b: ^Todo) -> bool { return a.id > b.id })

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

	tmpl := tmpl_index if full_page else tmpl_list
	bytes.buffer_grow(&res.body, tmpl.approx_bytes)
	tmpl.with(bytes.buffer_to_stream(&res.body), l)

	http.respond(res, http.Status.OK, http.Mime_Type.Html)
}
