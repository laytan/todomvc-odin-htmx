package main

import "core:encoding/base32"
import "core:log"
import "core:math/rand"
import "core:strings"
import "core:sync"
import "core:time"

import "vendor/http"
import "vendor/http/nbio"

Session :: struct {
	list:          [dynamic]^Todo,
	completed:     int,
	last_activity: time.Time,
}

Sessions :: struct {
	entries:            map[string]^Session,
	registered_cleaner: bool,
	mu:                 sync.RW_Mutex,
}

@(private = "file")
sessions: Sessions

/*
Makes sure every request has a valid session.
*/
session_middleware :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	session := session_get(req)
	if session != nil {
		h.next.?.handle(h.next.?, req, res)
		return
	}

	// Creates a random string of characters to represent this session.
	id: [16]byte
	n := rand.read(id[:])
	assert(n == 16)
	sid := base32.encode(id[:])

	session = new(Session)
	session.last_activity = time.now()
	{
		sync.guard(&sessions.mu)
		sessions.entries[sid] = session

		if !sessions.registered_cleaner {
			sessions.registered_cleaner = true
			sessions_register_cleaner(res._conn.server)
		}
	}

	append(&res.cookies, http.Cookie{name = "session", value = string(sid), path = "/"})

	// Make the browser make the request again, this time with the session set.
	// Probably not the greatest way of doing this lol.
	res.status = .Found
	res.headers["location"] = INDEX
	http.respond(res)
}

/*
Periodically checks for inactive sessions and deletes them.
*/
sessions_register_cleaner :: proc(s: ^http.Server) {
	CLEAN_INTERVAL :: time.Hour
	INACTIVE_TIME  :: time.Hour * 6

	clean_sessions :: proc(s: rawptr, now_: Maybe(time.Time)) {
		s := cast(^http.Server)s
		nbio.timeout(&s.io, CLEAN_INTERVAL, s, clean_sessions)

		now := now_.? or_else time.now()

		sync.guard(&sessions.mu)
		for sid, session in sessions.entries {
			if time.diff(session.last_activity, now) < INACTIVE_TIME {
				continue
			}

			log.infof("Deleting inactive session: %s", sid)

			for todo in session.list {
				delete(todo.title)
				free(todo)
			}

			delete(session.list)
			free(session)
			delete_key(&sessions.entries, sid)
			delete(sid)
		}
	}
	nbio.timeout(&s.io, CLEAN_INTERVAL, s, clean_sessions)
}

/*
Gets the session out of the request cookies.
*/
session_get :: proc(req: ^http.Request) -> ^Session {
	session: string
	if cookies, ok := req.headers["cookie"]; ok {
		if i := strings.last_index(cookies, "session="); i > -1 {
			session = cookies[i + len("session="):]
			if next := strings.index_byte(session, ';'); next > -1 {
				session = session[:next]
			}
		}
	}

	sync.shared_guard(&sessions.mu)
	s := sessions.entries[session]
	if s != nil do s.last_activity = time.now()
	return s
}

Item :: struct {
	todo:  ^Todo,
	index: int,
}
session_get_todo :: proc(session: ^Session, id: int) -> Maybe(Item) {
	for todo, i in session.list {
		if todo.id == id do return Item{todo, i}
	}
	return nil
}
