type t =
  | Line_without_files of { job : string }
  | Files_without_a_line of { job : string }

let divergences ~crontab_jobs ~payload_jobs =
  match (crontab_jobs, payload_jobs) with
  | None, None
  | None, Some _
  | Some _, None ->
      []
  | Some section, Some payloads ->
      let lines_without_files =
        List.filter (fun job -> not (List.mem job payloads)) section
        |> List.map (fun job -> Line_without_files { job })
      in
      let files_without_a_line =
        List.filter (fun job -> not (List.mem job section)) payloads
        |> List.sort String.compare
        |> List.map (fun job -> Files_without_a_line { job })
      in
      lines_without_files @ files_without_a_line

let remedy ~crontab_path ~payload_dir divergence =
  match divergence with
  | Line_without_files { job } ->
      Printf.sprintf
        "the crontab section fires %s and %s holds none of its payload files, \
         so the job fails at its next fire; no command clears this, so remove \
         %s's entry from %s by hand"
        job payload_dir job crontab_path
  | Files_without_a_line { job } ->
      Printf.sprintf
        "%s holds %s's payload files and no crontab line fires them, so the \
         job never runs; a bondi deploy of %s writes the line"
        payload_dir job job
