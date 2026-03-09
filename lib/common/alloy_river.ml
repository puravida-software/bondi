type collect_mode = All | Services_only

type config = {
  grafana_cloud_endpoint : string;
  grafana_cloud_instance_id : string;
  grafana_cloud_api_key : string;
  collect : collect_mode;
  labels : (string * string) list;
  excluded_containers : string list;
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
  (* Docker discovery *)
  add "discovery.docker \"containers\" {\n";
  add "\thost = \"unix:///var/run/docker.sock\"\n";
  add "\n";
  add "\tfilter {\n";
  add "\t\tname   = \"label\"\n";
  add "\t\tvalues = [\"bondi.managed=true\"]\n";
  add "\t}\n";
  add "}\n\n";
  (* Relabel rules for discovery *)
  add "discovery.relabel \"bondi\" {\n";
  add "\ttargets = discovery.docker.containers.targets\n";
  (* Collect mode filtering *)
  (match config.collect with
  | All -> ()
  | Services_only ->
      add "\n";
      add "\trule {\n";
      add "\t\tsource_labels = [\"bondi.type\"]\n";
      add "\t\tregex         = \"^(service|cron)$\"\n";
      add "\t\taction        = \"keep\"\n";
      add "\t}\n");
  (* Per-service logs opt-out via bondi.logs label *)
  add "\n";
  add "\trule {\n";
  add "\t\tsource_labels = [\"bondi.logs\"]\n";
  add "\t\tregex         = \"false\"\n";
  add "\t\taction        = \"drop\"\n";
  add "\t}\n";
  (* Excluded containers by name *)
  List.iter
    (fun name ->
      add "\n";
      add "\trule {\n";
      add "\t\tsource_labels = [\"__meta_docker_container_name\"]\n";
      add
        (Printf.sprintf "\t\tregex         = \".*%s.*\"\n" (escape_regex name));
      add "\t\taction        = \"drop\"\n";
      add "\t}\n")
    config.excluded_containers;
  add "}\n\n";
  (* Loki source *)
  add "loki.source.docker \"bondi\" {\n";
  add "\thost       = \"unix:///var/run/docker.sock\"\n";
  add "\ttargets    = discovery.relabel.bondi.output\n";
  add "\tforward_to = [loki.write.grafana_cloud.receiver]\n";
  add "}\n\n";
  (* Loki write *)
  add "loki.write \"grafana_cloud\" {\n";
  add "\tendpoint {\n";
  add (Printf.sprintf "\t\turl = \"%s\"\n" (esc config.grafana_cloud_endpoint));
  add "\n";
  add "\t\tbasic_auth {\n";
  add "\t\t\tusername = env(\"GRAFANA_CLOUD_INSTANCE_ID\")\n";
  add "\t\t\tpassword = env(\"GRAFANA_CLOUD_API_KEY\")\n";
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
