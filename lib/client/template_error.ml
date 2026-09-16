let message ~pp error =
  let buffer = Buffer.create 256 in
  let formatter = Format.formatter_of_buffer buffer in
  Format.pp_set_margin formatter 1_000_000;
  Format.fprintf formatter "%a@?" pp error;
  Buffer.contents buffer
