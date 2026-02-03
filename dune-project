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
  (alcotest
   (and
    (>= 1.9.1)
    :with-test))
  (dream
   (>= 1.0.0~alpha8))
  ocaml
  eio
  eio_main
  lwt_eio
  cohttp-eio
  yojson
  lwt
  uri
  base64
  ppx_yojson_conv
  ppx_deriving)
 (tags
  ("add topics" "to describe" your project)))
