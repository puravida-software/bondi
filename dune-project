(lang dune 3.20)

(name bondi)

(generate_opam_files true)

(source
 (github username/reponame))

(authors "Author Name <author@example.com>")

(maintainers "Maintainer Name <maintainer@example.com>")

(license LICENSE)

(documentation https://url/to/documentation)

(package
 (name bondi)
 (synopsis "A short synopsis")
 (description "A longer description")
 (depends
  ocaml
  eio
  eio_main
  lwt_eio
  cohttp-eio
  yojson
  lwt
  uri
  ppx_yojson_conv
  ppx_deriving)
 (tags
  ("add topics" "to describe" your project)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
