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
  (ocaml
   (>= 5.3.0))
  (ppx_deriving_yojson
   (>= 3.10.0))
  (ppx_deriving
   (>= 6.1.1))
  (lwt_ppx
   (>= 5.9.3))
  (alcotest
   (and
    (>= 1.9.1)
    :with-test))
  (dream
   (>= 1.0.0~alpha8))
  (cohttp
   (>= 6.2.1))
  (cohttp-eio
   (>= 6.2.1))
  (eio
   (>= 1.3))
  (eio_main
   (>= 1.3))
  (lwt
   (>= 5.9.2))
  (lwt_eio
   (>= 0.5.1))
  (mustache
   (>= 3.3.0))
  (yaml
   (>= 3.2.0))
  (yojson
   (>= 3.0.0))
  (uri
   (>= 4.4.0))
  (base64
   (>= 3.5.2))
  (cmdliner
   (>= 2.1.0))
  (ocamlformat
   (and
    (= 0.28.1)
    :with-dev-setup))
  (odoc
   (and
    (>= 3.1.0)
    :with-dev-setup))
  (opam-dune-lint
   (and
    (>= 0.6)
    :with-dev-setup))
  (ocaml-lsp-server
   (and
    (>= 1.23.1)
    :with-dev-setup)))
 (tags
  ("add topics" "to describe" your project)))