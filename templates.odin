package main

import "vendor/temple"

List :: struct {
	todos: []^Todo,
	count: Count,
	page:  Page,
}

Count :: struct {
	total:     int,
	active:    int,
	completed: int,
	oob:       bool,
}

count :: proc(session: ^Session) -> Count {
	return Count {
		total = len(session.list),
		completed = session.completed,
		active = len(session.list) - session.completed,
		oob = true,
	}
}

tmpl_index := temple.compiled("templates/index.temple.twig", List)
tmpl_list  := temple.compiled("templates/list.temple.twig",  List)
tmpl_todo  := temple.compiled("templates/todo.temple.twig", ^Todo)
tmpl_count := temple.compiled("templates/count.temple.twig", Count)
