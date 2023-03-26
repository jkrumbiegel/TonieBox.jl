# TonieBox

[![Build Status](https://github.com/jkrumbiegel/TonieBox.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/jkrumbiegel/TonieBox.jl/actions/workflows/CI.yml?query=branch%3Amain)


```julia
# run directly in REPL, asks for username and password
TonieBox.authenticate()

tonies = TonieBox.creativetonies()
tonie = first(tonie)

TonieBox.add_chapter_to_creative_tonie(tonie, path_to_mp3, "A title")
```