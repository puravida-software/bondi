type holder =
  | Builtin of string
  | Service of string
  | Blue_green_candidate of string
  | Managed of string
  | Cron_job of string

type collision = { job : string; holder : holder }

let name_of = function
  | Builtin name
  | Service name
  | Blue_green_candidate name
  | Managed name
  | Cron_job name ->
      name

let reserved ~service ~managed =
  let builtins =
    Builtin_container.[ orchestrator; traefik; alloy ]
    |> List.map (fun name -> Builtin name)
  in
  let service_holders =
    match service with
    | None -> []
    | Some service ->
        let name = Router_name.to_string service in
        [ Service name; Blue_green_candidate (name ^ "-new") ]
  in
  List.concat
    [ builtins; service_holders; List.map (fun name -> Managed name) managed ]

let collisions ~service ~managed jobs =
  let fixed = reserved ~service ~managed in
  let collisions_of ~earlier job =
    let with_fixed =
      List.filter (fun holder -> String.equal (name_of holder) job) fixed
    in
    let with_jobs =
      match List.exists (String.equal job) earlier with
      | true -> [ Cron_job job ]
      | false -> []
    in
    List.map (fun holder -> { job; holder }) (with_fixed @ with_jobs)
  in
  let _, reversed =
    List.fold_left
      (fun (earlier, acc) job ->
        (job :: earlier, List.rev_append (collisions_of ~earlier job) acc))
      ([], []) jobs
  in
  List.rev reversed

let holder_description = function
  | Builtin name -> Printf.sprintf "the built-in container %S" name
  | Service name -> Printf.sprintf "the service %S" name
  | Blue_green_candidate name ->
      Printf.sprintf "the service's blue-green candidate %S" name
  | Managed name -> Printf.sprintf "the managed container %S" name
  | Cron_job name -> Printf.sprintf "another cron job %S" name

let collision_to_string { job; holder } =
  Printf.sprintf
    "cron job %S cannot take that name: %s already runs under it, and a cron \
     job's container is named after the job"
    job
    (holder_description holder)

let refusal = function
  | [] -> None
  | collisions ->
      Some
        (Printf.sprintf
           "cron jobs cannot take names already in use (%s): rename these jobs \
            in bondi.yaml"
           (String.concat "; " (List.map collision_to_string collisions)))

let is_safe_path_name = Managed_container.is_valid_name

let unsafe_path_refusal names =
  match List.filter (fun name -> not (is_safe_path_name name)) names with
  | [] -> None
  | offenders ->
      Some
        (Printf.sprintf
           "cron job names must be safe to place in a file path (%s). A name \
            must begin with a letter or a digit and may hold only letters, \
            digits, '.', '_' and '-': rename these jobs in bondi.yaml"
           (String.concat ", " (List.map (Printf.sprintf "%S") offenders)))
