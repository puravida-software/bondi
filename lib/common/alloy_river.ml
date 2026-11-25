type collect_mode = All | Services_only

module Max_backoff_retries = struct
  type t = int

  let of_int n =
    if n < 0 then
      Error
        (Printf.sprintf
           "%d is negative; a retry limit is 0 (retry indefinitely) or more" n)
    else Ok n

  let to_int t = t
end

type config = {
  grafana_cloud_endpoint : string;
  grafana_cloud_instance_id : string;
  grafana_cloud_api_key : string;
  collect : collect_mode;
  labels : (string * string) list;
  excluded_containers : string list;
  max_backoff_retries : Max_backoff_retries.t option;
}

let collect_mode_of_string = function
  | "all" -> Ok All
  | "services_only" -> Ok Services_only
  | s ->
      Error
        (Printf.sprintf
           "invalid collect mode: %S, expected \"all\" or \"services_only\"" s)

let escape_river_string s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '\\' -> Buffer.add_string buf "\\\\"
      | '"' -> Buffer.add_string buf "\\\""
      | '\n' -> Buffer.add_string buf "\\n"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let escape_regex s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '.'
      | '*'
      | '+'
      | '?'
      | '('
      | ')'
      | '['
      | ']'
      | '{'
      | '}'
      | '^'
      | '$'
      | '|'
      | '\\' ->
          Buffer.add_char buf '\\';
          Buffer.add_char buf c
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let pad_right s width =
  let len = String.length s in
  if len >= width then s else s ^ String.make (width - len) ' '

let generate (config : config) : string =
  let buf = Buffer.create 1024 in
  let add = Buffer.add_string buf in
  let esc = escape_river_string in
  (* One drop rule per excluded name, over the label that carries the container
     name on the path being relabelled. *)
  let add_exclusions source_label =
    List.iter
      (fun name ->
        add "\n";
        add "\trule {\n";
        add (Printf.sprintf "\t\tsource_labels = [\"%s\"]\n" source_label);
        add
          (Printf.sprintf "\t\tregex         = \".*%s.*\"\n" (escape_regex name));
        add "\t\taction        = \"drop\"\n";
        add "\t}\n")
      config.excluded_containers
  in
  (* Docker discovery *)
  add "discovery.docker \"containers\" {\n";
  add "\thost = \"unix:///var/run/docker.sock\"\n";
  add "\n";
  (* Its own paragraph, so [host] keeps the alignment it had before the
     interval was written. Every 5s rather than Alloy's [1m], so a container
     that runs past about 15 s is read even if it's gone within a minute; one
     that exits sooner may still be missed. Alloy v1.8.0 began reading a new
     container 11 to 15 s after it started [observed -- 2026-11-24, Docker
     Engine 29.10.0, five starts]. *)
  add "\trefresh_interval = \"5s\"\n";
  add "\n";
  add "\tfilter {\n";
  add "\t\tname   = \"label\"\n";
  add "\t\tvalues = [\"bondi.managed=true\"]\n";
  add "\t}\n";
  add "}\n\n";
  (* Relabel rules for discovery *)
  add "discovery.relabel \"bondi\" {\n";
  add "\ttargets = discovery.docker.containers.targets\n";
  (* The rules read labels by the names Docker discovery gives them: a container
     label [bondi.x] reaches a target as
     [__meta_docker_container_label_bondi_x], and no target carries a label
     spelled [bondi.x]. A rule naming that spelling reads an empty value on
     every target, so a [keep] keeps nothing and a [drop] drops nothing. *)
  (* Cron containers never ship from this path, under either mode: their lines
     come from the journal source below. A pass can exit before discovery lists
     it, so this path would miss most passes, and ship again the ones it did
     list. *)
  add "\n";
  add "\trule {\n";
  add "\t\tsource_labels = [\"__meta_docker_container_label_bondi_type\"]\n";
  add "\t\tregex         = \"cron\"\n";
  add "\t\taction        = \"drop\"\n";
  add "\t}\n";
  (* Collect mode filtering *)
  (match config.collect with
  | All -> ()
  | Services_only ->
      add "\n";
      add "\trule {\n";
      add "\t\tsource_labels = [\"__meta_docker_container_label_bondi_type\"]\n";
      add "\t\tregex         = \"^service$\"\n";
      add "\t\taction        = \"keep\"\n";
      add "\t}\n");
  (* Per-service logs opt-out via bondi.logs label *)
  add "\n";
  add "\trule {\n";
  add "\t\tsource_labels = [\"__meta_docker_container_label_bondi_logs\"]\n";
  add "\t\tregex         = \"false\"\n";
  add "\t\taction        = \"drop\"\n";
  add "\t}\n";
  (* Excluded containers by name *)
  add_exclusions "__meta_docker_container_name";
  (* The [container] label names the workload a line came from. It is written
     to a label of its own, so the rules above read the raw container name
     whatever order they come in. The container name, without the leading [/]
     Docker gives it, is the fallback, for containers started before
     [bondi.name] was set on them. The second rule overrides it when
     [bondi.name] is non-empty: a cron pass and a blue-green candidate run
     under a temporary name that differs from run to run, and [bondi.name]
     holds the one that does not. The order is the precedence: swapped, the
     temporary name would win. *)
  add "\n";
  add "\trule {\n";
  add "\t\tsource_labels = [\"__meta_docker_container_name\"]\n";
  add "\t\tregex         = \"/(.*)\"\n";
  add "\t\ttarget_label  = \"container\"\n";
  add "\t\treplacement   = \"$1\"\n";
  add "\t\taction        = \"replace\"\n";
  add "\t}\n";
  add "\n";
  add "\trule {\n";
  add "\t\tsource_labels = [\"__meta_docker_container_label_bondi_name\"]\n";
  add "\t\tregex         = \"(.+)\"\n";
  add "\t\ttarget_label  = \"container\"\n";
  add "\t\treplacement   = \"$1\"\n";
  add "\t\taction        = \"replace\"\n";
  add "\t}\n";
  add "}\n\n";
  (* Loki source *)
  add "loki.source.docker \"bondi\" {\n";
  add "\thost       = \"unix:///var/run/docker.sock\"\n";
  add "\ttargets    = discovery.relabel.bondi.output\n";
  add "\tforward_to = [loki.write.grafana_cloud.receiver]\n";
  add "}\n\n";
  (* Relabel rules for the journal. Collect mode does not apply: cron is kept
     under both modes, and only cron entries are read. The rules read the
     driver's journal fields by the names Alloy gives them: a container label
     [bondi.x] is written as the field [BONDI_X] and reaches a rule as
     [__journal_bondi_x]; the container name is [__journal_container_name],
     with no leading [/]. *)
  add "loki.relabel \"bondi_cron\" {\n";
  add "\tforward_to = []\n";
  add "\n";
  add "\trule {\n";
  add "\t\tsource_labels = [\"__journal_bondi_logs\"]\n";
  add "\t\tregex         = \"false\"\n";
  add "\t\taction        = \"drop\"\n";
  add "\t}\n";
  add_exclusions "__journal_container_name";
  (* The same precedence as the Docker path: the container name first, then
     [bondi.name] over it when non-empty, so a pass's timestamped name never
     wins. *)
  add "\n";
  add "\trule {\n";
  add "\t\tsource_labels = [\"__journal_container_name\"]\n";
  add "\t\tregex         = \"(.+)\"\n";
  add "\t\ttarget_label  = \"container\"\n";
  add "\t\treplacement   = \"$1\"\n";
  add "\t\taction        = \"replace\"\n";
  add "\t}\n";
  add "\n";
  add "\trule {\n";
  add "\t\tsource_labels = [\"__journal_bondi_name\"]\n";
  add "\t\tregex         = \"(.+)\"\n";
  add "\t\ttarget_label  = \"container\"\n";
  add "\t\treplacement   = \"$1\"\n";
  add "\t\taction        = \"replace\"\n";
  add "\t}\n";
  (* The journal source labels each entry [job], which the Docker path does not
     carry. Dropped, a cron stream carries the labels a service stream does. *)
  add "\n";
  add "\trule {\n";
  add "\t\tregex  = \"job\"\n";
  add "\t\taction = \"labeldrop\"\n";
  add "\t}\n";
  add "}\n\n";
  (* Journal source. The matches are ANDed, so an entry needs both fields: a
     container outside Bondi, or a Bondi container of another type, is never
     read. *)
  add "loki.source.journal \"bondi_cron\" {\n";
  add (Printf.sprintf "\tpath          = \"%s\"\n" Defaults.journal_path);
  add "\tmatches       = \"BONDI_MANAGED=true BONDI_TYPE=cron\"\n";
  add "\trelabel_rules = loki.relabel.bondi_cron.rules\n";
  add "\tforward_to    = [loki.write.grafana_cloud.receiver]\n";
  add "}\n\n";
  (* Loki write *)
  add "loki.write \"grafana_cloud\" {\n";
  add "\tendpoint {\n";
  add (Printf.sprintf "\t\turl = \"%s\"\n" (esc config.grafana_cloud_endpoint));
  add "\n";
  (* Its own paragraph, so [url] keeps the alignment it has without it and an
     unset limit leaves the config exactly as it was. *)
  (match config.max_backoff_retries with
  | None -> ()
  | Some limit ->
      add
        (Printf.sprintf "\t\tmax_backoff_retries = %d\n"
           (Max_backoff_retries.to_int limit));
      add "\n");
  add "\t\tbasic_auth {\n";
  add "\t\t\tusername = sys.env(\"GRAFANA_CLOUD_INSTANCE_ID\")\n";
  add "\t\t\tpassword = sys.env(\"GRAFANA_CLOUD_API_KEY\")\n";
  add "\t\t}\n";
  add "\t}\n";
  (* Custom labels *)
  (match config.labels with
  | [] -> ()
  | labels ->
      let max_key_len =
        List.fold_left
          (fun acc (key, _) -> max acc (String.length (esc key)))
          0 labels
      in
      add "\texternal_labels = {\n";
      List.iter
        (fun (key, value) ->
          add
            (Printf.sprintf "\t\t%s = \"%s\",\n"
               (pad_right (esc key) max_key_len)
               (esc value)))
        labels;
      add "\t}\n");
  add "}\n";
  Buffer.contents buf

(* The values are written literally. [docker run --env-file] reads a value as
   everything after the first [=] to the end of the line and has no quoting or
   escaping syntax at all, so there is nothing correct to escape to -- a value
   carrying a control character would declare a variable nobody wrote. That is
   why the guard is a rejection at the boundary instead: the client's config
   reader refuses such a value when it reads the [alloy] block, so what reaches
   here is already a value this format can carry. The pair of names is kept in
   the order [generate] reads them. *)
let env_file_contents (config : config) : string =
  Printf.sprintf "GRAFANA_CLOUD_INSTANCE_ID=%s\nGRAFANA_CLOUD_API_KEY=%s\n"
    config.grafana_cloud_instance_id config.grafana_cloud_api_key
