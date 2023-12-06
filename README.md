# Todo MVC using Odin and HTMX

An implementation of [Todo MVC](https://todomvc.com/) using my in development [Odin](https://odin-lang.org/) web stack and [HTMX](https://htmx.org).

Using my own packages:
- [Odin-HTTP](https://github.com/laytan/odin-http)
- [Temple (templating engine)](https://github.com/laytan/temple)
- [Obacktracing (printing stacktraces on segfaults or panics)](https://github.com/laytan/obacktracing)

This is mainly here to dogfood the libraries and provide an example.

The docker container does not work on the arm architecture currently because of [a bug](https://github.com/odin-lang/Odin/issues/2793) in Odin.

## Compiling

First compile the templating engine: `odin build vendor/temple/cli -out:./temple`.

Then compile the templates: `./temple . vendor/temple`

Then the project: `odin build .`

## Deployment

The project is deployed on [Render](https://render.com) using the Dockerfile in this repo,
with a [Cloudflare](https://cloudflare.com) proxy in front.
