module String_utils = Bondi_common.String_utils

let ( let* ) = Result.bind

type encryption = Unencrypted | Encrypted of { cipher : string }
type unreadable = No_armour | Body_not_base64 | Body_not_openssh of string

let decode contents =
  match Base64.decode contents with
  | Ok decoded -> decoded
  | Error _ -> contents

(* Which PEM container the armour says this is. The two named arms state their
   own encryption in the armour and nowhere a reader that does not parse DER
   can reach a cipher name, so recognising them is the whole of reading them.
   [Other] is not "not a key" -- it is every container this module goes on to
   read properly, and every one it cannot read at all. *)
type container = Traditional_pem | Pkcs8 | Other

let traditional_pem_header = "Proc-Type: 4,ENCRYPTED"
let pkcs8_marker = "-----BEGIN ENCRYPTED PRIVATE KEY-----"
let armour_marker = "-----BEGIN"
let armour_line_prefix = "-----"
let openssh_magic = "openssh-key-v1\000"

(* The cipher name field begins immediately after the magic, as a big-endian
   [uint32] length followed by that many bytes. *)
let cipher_length_offset = String.length openssh_magic
let cipher_length_bytes = 4
let cipher_name_offset = cipher_length_offset + cipher_length_bytes
let unencrypted_cipher_name = "none"

let container_of decoded =
  match String_utils.contains ~needle:traditional_pem_header decoded with
  | true -> Traditional_pem
  | false -> (
      match String_utils.contains ~needle:pkcs8_marker decoded with
      | true -> Pkcs8
      | false -> Other)

(* What was found where the magic was expected, escaped and bounded, so a
   rejection is readable without the key in hand and cannot itself carry a
   key's worth of bytes into a message. *)
let leading value =
  String.escaped
    (String.sub value 0
       (min (String.length value) (String.length openssh_magic)))

(* The base64 between the armour markers. PEM header lines carry a colon and no
   base64, and the blank line that follows them carries nothing, so dropping
   every line that is not body leaves the body. *)
let armoured_body decoded =
  match String_utils.contains ~needle:armour_marker decoded with
  | false -> Error No_armour
  | true ->
      Ok
        (String.split_on_char '\n' decoded
        |> List.map String.trim
        |> List.filter (fun line ->
            not
              (String.equal line ""
              || String_utils.starts_with ~prefix:armour_line_prefix line
              || String_utils.contains ~needle:":" line))
        |> String.concat "")

let decoded_body body =
  match Base64.decode body with
  | Ok raw -> Ok raw
  | Error _ -> Error Body_not_base64

let uint32_be value offset =
  (Char.code value.[offset] lsl 24)
  lor (Char.code value.[offset + 1] lsl 16)
  lor (Char.code value.[offset + 2] lsl 8)
  lor Char.code value.[offset + 3]

(* The length is read as a [uint32] into an [int], which is 31 bits wide on a
   32-bit platform: a leading byte of [0x40] or more overflows it and the
   result is negative. [length >= 0] is what keeps the bounds check a bounds
   check -- without it a negative length passes the comparison and
   [String.sub] raises, out of a module whose whole contract is to answer a
   value for every input, on a field an operator's manifest supplies. *)
let cipher_name raw =
  match
    String_utils.starts_with ~prefix:openssh_magic raw
    && String.length raw >= cipher_name_offset
  with
  | false -> Error (Body_not_openssh (leading raw))
  | true ->
      let length = uint32_be raw cipher_length_offset in
      if length >= 0 && String.length raw >= cipher_name_offset + length then
        Ok (String.sub raw cipher_name_offset length)
      else Error (Body_not_openssh (leading raw))

let encryption contents =
  let decoded = decode contents in
  match container_of decoded with
  | Traditional_pem -> Ok (Encrypted { cipher = "pem" })
  | Pkcs8 -> Ok (Encrypted { cipher = "pkcs8" })
  | Other ->
      let* body = armoured_body decoded in
      let* raw = decoded_body body in
      let* name = cipher_name raw in
      if String.equal name unencrypted_cipher_name then Ok Unencrypted
      else Ok (Encrypted { cipher = name })

(* A string, and the [.mli] is what makes that fact unreachable: with no
   printer and one named extractor, the only way a passphrase becomes text
   again is a call a reader can grep for. *)
type passphrase = string

let passphrase value =
  match String.equal value "" with
  | true -> None
  | false -> Some value

let expose_to_askpass value = value

type refusal =
  | Encrypted_without_passphrase of { cipher : string }
  | Unreadable_body of { detail : string }

type identity =
  | Ambient
  | Staged_key
  | Own_agent of { passphrase : passphrase }
  | Refused of { reason : refusal }

(* What is wrong with a body that had armour around it, in the words a refusal
   carries. Built here rather than in the message so that the two arms
   [identity] can reach are the only ones that have a phrase at all: [No_armour]
   never becomes a refusal and therefore never needs one. *)
let body_not_base64_detail = "the body between the armour markers is not base64"

let body_not_openssh_detail found =
  Printf.sprintf
    "the body decoded and did not begin with the OpenSSH key magic; found %S"
    found

let identity ~contents ~passphrase:supplied =
  match contents with
  | None -> Ambient
  | Some contents -> (
      match encryption contents with
      (* No armour at all is a format this module has not met -- staged and left
         to ssh, which is the authority on a usable key. Armour and an
         unreadable body is not that: the value says which container it is and
         then does not hold one, and the commonest way to arrive here is a
         multi-line key substituted into a quoted YAML scalar and folded onto a
         single line. Staging that offers the host a key that cannot sign and
         collects the host's verdict on a local fault, which is the failure this
         module exists to stop. *)
      | Error No_armour -> Staged_key
      | Error Body_not_base64 ->
          Refused
            { reason = Unreadable_body { detail = body_not_base64_detail } }
      | Error (Body_not_openssh found) ->
          Refused
            {
              reason =
                Unreadable_body { detail = body_not_openssh_detail found };
            }
      | Ok Unencrypted -> Staged_key
      | Ok (Encrypted { cipher }) -> (
          match Option.bind supplied passphrase with
          | Some passphrase -> Own_agent { passphrase }
          | None -> Refused { reason = Encrypted_without_passphrase { cipher } }
          ))

let refusal_message ~server ~reason =
  match reason with
  | Encrypted_without_passphrase { cipher } ->
      Printf.sprintf
        "server %s: the private key in ssh.private_key_contents is encrypted \
         (%s) and ssh.private_key_pass is empty; set the passphrase, or remove \
         the key and let ssh use your own configuration"
        server cipher
  | Unreadable_body { detail } ->
      Printf.sprintf
        "server %s: the private key in ssh.private_key_contents has PEM armour \
         around a body this client cannot read -- %s; a key substituted into a \
         quoted scalar is folded onto one line and stops being a key, so carry \
         it base64-encoded or as a block scalar, or remove the key and let ssh \
         use your own configuration"
        server detail
