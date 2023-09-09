# Todo MVC using Odin and Htmx

An implementation of [Todo MVC](https://todomvc.com/) using my in development [Odin](https://odin-lang.org/) web stack.

Using my own libraries:
- [Odin-HTTP](https://github.com/laytan/odin-http)
- [Temple (templating engine)](https://github.com/laytan/temple)

This is mainly here to dogfood the libraries and provide an example.
While making this I was able to create a big list of features and fixes that need to be added to the stack.

This does not work on Linux currently because of [a bug](https://github.com/odin-lang/Odin/issues/2793) in Odin (using the Dockerfile for example).

## Compiling

First compile the templating engine: `odin build vendor/temple/cli -out:./temple`.

Then compile the templates: `./temple . vendor/temple`

Then the project: `odin build .`
