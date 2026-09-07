module Health = Bondi_server__Health
module Handler_error = Bondi_server__Handler_error

(* [Health.health] is the one extracted body with no gather and no plan beneath
   it, so nothing below it can carry its test. Rendering the result rather than
   matching on it keeps the failure message readable: a body that started
   reporting a failure names it here instead of failing on a bare [Ok ()]. *)
let show_health = function
  | Ok () -> "Ok"
  | Error err -> "Error(" ^ Handler_error.message err ^ ")"

(* The [Error] arm exists because it is the shape every endpoint's body has, not
   because this one can fail today. This pins the answer the route encodes as
   204, so a readiness check added later has to change the test that says so. *)
let test_health_answers_ok () =
  Alcotest.(check string)
    "health answers Ok, which the route encodes as 204" "Ok"
    (show_health (Health.health ()))

let () =
  Alcotest.run "Health"
    [
      ( "health",
        [
          Alcotest.test_case "answers Ok, which the route sends as 204" `Quick
            test_health_answers_ok;
        ] );
    ]
