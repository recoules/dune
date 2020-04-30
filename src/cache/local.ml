open Stdune
open Result.O
open Cache_intf

type t =
  { root : Path.t
  ; build_root : Path.t option
  ; info : User_message.Style.t Pp.t list -> unit
  ; warn : User_message.Style.t Pp.t list -> unit
  ; repositories : repository list
  ; command_handler : command -> unit
  ; duplication_mode : Duplication_mode.t
  ; temp_dir : Path.t
  }

module Trimming_result = struct
  type t =
    { trimmed_files_size : int
    ; trimmed_files : Path.t list
    ; trimmed_metafiles : Path.t list
    }

  let empty =
    { trimmed_files_size = 0; trimmed_files = []; trimmed_metafiles = [] }

  let add t ~size ~file =
    { t with
      trimmed_files = file :: t.trimmed_files
    ; trimmed_files_size = size + t.trimmed_files_size
    }
end

let default_root () =
  Path.L.relative (Path.of_string Xdg.cache_dir) [ "dune"; "db" ]

let file_store_version = "v3"

let metadata_store_version = "v3"

let file_store_root cache =
  Path.L.relative cache.root [ "files"; file_store_version ]

let metadata_store_root cache =
  Path.L.relative cache.root [ "meta"; metadata_store_version ]

let detect_unexpected_dirs_under_cache_root cache =
  let expected_in_root path =
    (* We only report unexpected directories, since quite a few temporary files
       are created at the cache root, and it would be tedious to keep track of
       all of them. *)
    match (Path.is_directory (Path.relative cache.root path), path) with
    | false, _ -> true
    | true, "files"
    | true, "meta"
    | true, "runtime" ->
      true
    | true, dir -> String.is_prefix ~prefix:"promoting." dir
  in
  let open Result.O in
  let expected_in_files = String.equal file_store_version in
  let expected_in_meta = String.equal metadata_store_version in
  let detect_in ~dir expected =
    let+ names = Path.readdir_unsorted dir in
    List.filter_map names ~f:(fun name ->
        Option.some_if (not (expected name)) (Path.relative dir name))
  in
  let+ in_root = detect_in ~dir:cache.root expected_in_root
  and+ in_files =
    detect_in ~dir:(Path.relative cache.root "files") expected_in_files
  and+ in_meta =
    detect_in ~dir:(Path.relative cache.root "meta") expected_in_meta
  in
  List.sort ~compare:Path.compare (in_root @ in_files @ in_meta)

(* A file storage scheme. *)
module type FSScheme = sig
  (* Given a cache root and a file digest, determine the location of the file in
     the cache. *)
  val path : root:Path.t -> Digest.t -> Path.t

  (* Given a cache root, list all files stored in the cache. *)
  val list : root:Path.t -> Path.t list
end

(* A file storage scheme where a file with a digest [d] is stored in a
   subdirectory whose name is made of the first two characters of [d], that is:

   [<root>/<first-two-characters-of-d>/<d>]

   CR-someday amokhov: We currently do not provide support for collisions where
   two or more files with different content have the same content digest [d]. If
   this ever becomes a real (i.e. not hypothetical) problem, a good way forward
   would be to switch from MD5 to SHA1 or higher, making the chance of this
   happening even lower, and at the same time making it more difficult to create
   deliberate collisions. *)
module FirstTwoCharsSubdir : FSScheme = struct
  let path ~root digest =
    let digest = Digest.to_string digest in
    let first_two_chars = String.sub digest ~pos:0 ~len:2 in
    Path.L.relative root [ first_two_chars; digest ]

  let list ~root =
    let open Result.O in
    let f dir =
      let is_hex_char = function
        | '0' .. '9'
        | 'a' .. 'f' ->
          true
        | _non_hex_char -> false
      and root = Path.L.relative root [ dir ] in
      if String.for_all ~f:is_hex_char dir then
        let+ paths = Path.readdir_unsorted root in
        List.map ~f:(Path.relative root) paths
      else
        Ok []
    in
    match Path.readdir_unsorted root >>= Result.List.concat_map ~f with
    | Ok res -> res
    | Error e -> User_error.raise [ Pp.text (Unix.error_message e) ]
end

module FSSchemeImpl = FirstTwoCharsSubdir

let metadata_path cache key =
  FSSchemeImpl.path ~root:(metadata_store_root cache) key

let file_path cache key = FSSchemeImpl.path ~root:(file_store_root cache) key

module Metadata_file = struct
  type t =
    { metadata : Sexp.t list
    ; files : File.t list
    }

  let to_sexp { metadata; files } =
    let open Sexp in
    let f ({ path; digest } : File.t) =
      Sexp.List
        [ Sexp.Atom (Path.Local.to_string (Path.Build.local path))
        ; Sexp.Atom (Digest.to_string digest)
        ]
    in
    List
      [ List (Atom "metadata" :: metadata)
      ; List (Atom "files" :: List.map ~f files)
      ]

  let of_sexp = function
    | Sexp.List
        [ List (Atom "metadata" :: metadata); List (Atom "files" :: produced) ]
      ->
      let+ files =
        Result.List.map produced ~f:(function
          | List [ Atom path; Atom digest ] ->
            let path = Path.Build.of_string path in
            let+ digest =
              match Digest.from_hex digest with
              | Some digest -> Ok digest
              | None -> Error "Invalid digest in cache metadata"
            in
            { File.path; digest }
          | _ -> Error "Invalid list of produced files in cache metadata")
      in
      { metadata; files }
    | _ -> Error "Invalid cache metadata"

  let of_string s =
    match Csexp.parse_string s with
    | Ok sexp -> of_sexp sexp
    | Error (_, msg) -> Error msg

  let to_string f = to_sexp f |> Csexp.to_string

  let parse path = Io.with_file_in path ~f:Csexp.input >>= of_sexp
end

let tmp_path cache name =
  let res = Path.relative cache.temp_dir name in
  Path.mkdir_p res;
  res

let make_path cache path =
  match cache.build_root with
  | Some p -> Result.ok (Path.append_local p path)
  | None ->
    Result.Error
      (sprintf "relative path %s while no build root was set"
         (Path.Local.to_string_maybe_quoted path))

let with_repositories cache repositories = Result.Ok { cache with repositories }

let duplicate ?(duplication = None) cache ~src ~dst =
  match Option.value ~default:cache.duplication_mode duplication with
  | Copy -> Io.copy_file ~src ~dst ()
  | Hardlink -> Path.link src dst

let retrieve cache (file : File.t) =
  let src = file_path cache file.digest in
  let dst = Path.build file.path in
  cache.info
    [ Pp.textf "retrieve %s from cache" (Path.to_string_maybe_quoted dst) ];
  duplicate cache ~src ~dst;
  dst

let deduplicate cache (file : File.t) =
  match cache.duplication_mode with
  | Copy -> ()
  | Hardlink -> (
    let path = Path.Build.to_string file.path in
    let path_in_cache = file_path cache file.digest |> Path.to_string in
    let tmpname = Path.Build.to_string (Path.Build.of_string ".dedup") in
    cache.info [ Pp.textf "deduplicate %s from %s" path path_in_cache ];
    let rm p = try Unix.unlink p with _ -> () in
    try
      rm tmpname;
      Unix.link path_in_cache tmpname;
      Unix.rename tmpname path
    with Unix.Unix_error (e, syscall, _) ->
      rm tmpname;
      cache.warn
        [ Pp.textf "error handling dune-cache command: %s: %s" syscall
            (Unix.error_message e)
        ] )

let apply ~f o v =
  match o with
  | Some o -> f v o
  | None -> v

let promote_sync cache paths key metadata ~repository ~duplication =
  let open Result.O in
  let* repo =
    match repository with
    | Some idx -> (
      match List.nth cache.repositories idx with
      | None -> Result.Error (Printf.sprintf "repository out of range: %i" idx)
      | repo -> Result.Ok repo )
    | None -> Result.Ok None
  in
  let metadata =
    apply
      ~f:(fun metadata repository ->
        metadata
        @ [ Sexp.List [ Sexp.Atom "repo"; Sexp.Atom repository.remote ]
          ; Sexp.List [ Sexp.Atom "commit_id"; Sexp.Atom repository.commit ]
          ])
      repo metadata
  in
  let promote (path, expected_digest) =
    let* abs_path = make_path cache (Path.Build.local path) in
    cache.info [ Pp.textf "promote %s" (Path.to_string abs_path) ];
    let stat = Unix.lstat (Path.to_string abs_path) in
    let* stat =
      if stat.st_kind = S_REG then
        Result.Ok stat
      else
        Result.Error
          (Format.sprintf "invalid file type: %s"
             (Path.string_of_file_kind stat.st_kind))
    in
    (* Create a duplicate (either a [Copy] or a [Hardlink] depending on the
       [duplication] setting) of the promoted file in a temporary directory to
       correctly handle the situation when the file is modified or deleted
       during the promotion process. *)
    let tmp =
      let dst = Path.relative cache.temp_dir "data" in
      if Path.exists dst then Path.unlink dst;
      duplicate ~duplication cache ~src:abs_path ~dst;
      dst
    in
    let effective_digest = Digest.file_with_stats tmp (Path.stat tmp) in
    if Digest.compare effective_digest expected_digest != Ordering.Eq then (
      let message =
        Printf.sprintf "digest mismatch: %s != %s"
          (Digest.to_string effective_digest)
          (Digest.to_string expected_digest)
      in
      cache.info [ Pp.text message ];
      Result.Error message
    ) else
      let in_the_cache = file_path cache effective_digest in
      (* CR-soon: we assume that if the file with [effective_digest] exists in
         the file storage, then its content matches the digest, i.e. the user
         never modifies it. In principle, we could add a consistency check but
         this would have a non-negligible performance cost. A good compromise
         seems to be to add a "paranoid" mode to Dune cache where we always
         check file contents for consistency with the expected digest, so one
         could enable it when needed. In the paranoid mode, we could futhermore
         check for a digest collision via [Io.compare_files in_the_cache tmp]. *)
      match Path.exists in_the_cache with
      | true ->
        (* We no longer need the temporary file. *)
        Path.unlink tmp;
        (* Update the timestamp of the existing cache entry, moving it to the
           back of the trimming queue. *)
        Path.touch in_the_cache;
        Result.Ok (Already_promoted { path; digest = effective_digest })
      | false ->
        Path.mkdir_p (Path.parent_exn in_the_cache);
        let dest = Path.to_string in_the_cache in
        (* Move the temporary file to the cache. *)
        Unix.rename (Path.to_string tmp) dest;
        (* Remove write permissions, making the cache entry immutable. We assume
           that users do not modify the files in the cache. *)
        Unix.chmod dest (stat.st_perm land 0o555);
        Result.Ok (Promoted { path; digest = effective_digest })
  in
  let+ promoted = Result.List.map ~f:promote paths in
  let metadata_path = metadata_path cache key
  and metadata_tmp_path = Path.relative cache.temp_dir "metadata"
  and files =
    List.map promoted ~f:(function
        | Already_promoted f
        | Promoted f
        -> f)
  in
  let metadata_file : Metadata_file.t = { metadata; files } in
  let metadata = Csexp.to_string (Metadata_file.to_sexp metadata_file) in
  Io.write_file metadata_tmp_path metadata;
  let () =
    match Io.read_file metadata_path with
    | contents ->
      if contents <> metadata then
        User_warning.emit
          [ Pp.textf "non reproductible collision on rule %s"
              (Digest.to_string key)
          ]
    | exception Sys_error _ -> Path.mkdir_p (Path.parent_exn metadata_path)
  in
  Path.rename metadata_tmp_path metadata_path;
  (* The files that have already been present in the cache can be deduplicated,
     i.e. replaced with hardlinks to their cached copies. *)
  ( match cache.duplication_mode with
  | Copy -> ()
  | Hardlink ->
    List.iter promoted ~f:(function
      | Already_promoted file -> cache.command_handler (Dedup file)
      | _ -> ()) );
  (metadata_file, promoted)

let promote cache paths key metadata ~repository ~duplication =
  Result.map ~f:ignore
    (promote_sync cache paths key metadata ~repository ~duplication)

let search cache key =
  let path = metadata_path cache key in
  let* sexp =
    try Io.with_file_in path ~f:Csexp.input
    with Sys_error _ -> Error "no cached file"
  in
  let+ metadata = Metadata_file.of_sexp sexp in
  (* Touch cache files so they are removed last by LRU trimming. *)
  let () =
    let f (file : File.t) =
      (* There is no point in trying to trim out files that are missing : dune
         will have to check when hardlinking anyway since they could disappear
         inbetween. *)
      try Path.touch ~create:false (file_path cache file.digest)
      with Unix.(Unix_error (ENOENT, _, _)) -> ()
    in
    List.iter ~f metadata.files
  in
  (metadata.metadata, metadata.files)

let set_build_dir cache p = Result.Ok { cache with build_root = Some p }

let teardown cache = Path.rm_rf ~allow_external:true cache.temp_dir

let hint _ _ = Result.Ok ()

let detect_duplication_mode root =
  let () = Path.mkdir_p root in
  let beacon = Path.relative root "beacon"
  and target = Path.relative Path.build_dir ".cache-beacon" in
  let () = Path.touch beacon in
  let rec test () =
    match Path.link beacon target with
    | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
      Path.unlink_no_err target;
      test ()
    | exception Unix.Unix_error _ -> Duplication_mode.Copy
    | () -> Duplication_mode.Hardlink
  in
  test ()

let make ?(root = default_root ())
    ?(duplication_mode = detect_duplication_mode root)
    ?(log = Dune_util.Log.info) ?(warn = fun pp -> User_warning.emit pp)
    ~command_handler () =
  let res =
    { root
    ; build_root = None
    ; info = log
    ; warn
    ; repositories = []
    ; command_handler
    ; duplication_mode
    ; temp_dir =
        (* CR-soon amokhov: Introduce [val getpid : unit -> t] in [pid.ml] so
           that we don't use the untyped version of pid anywhere. *)
        Path.temp_dir ~temp_dir:root "promoting."
          ("." ^ string_of_int (Unix.getpid ()))
    }
  in
  match
    Path.mkdir_p @@ file_store_root res;
    Path.mkdir_p @@ metadata_store_root res
  with
  | () -> Ok res
  | exception exn ->
    Error
      ("Unable to set up the cache root directory: " ^ Printexc.to_string exn)

let duplication_mode cache = cache.duplication_mode

let trimmable stats = stats.Unix.st_nlink = 1

let _garbage_collect default_trim cache =
  let root = metadata_store_root cache in
  let metas =
    List.map ~f:(fun p -> (p, Metadata_file.parse p)) (FSSchemeImpl.list ~root)
  in
  let f default_trim = function
    | p, Result.Error msg ->
      cache.warn
        [ Pp.textf "remove invalid metadata file %s: %s"
            (Path.to_string_maybe_quoted p)
            msg
        ];
      Path.unlink_no_err p;
      { default_trim with Trimming_result.trimmed_metafiles = [ p ] }
    | p, Result.Ok { Metadata_file.files; _ } ->
      if
        List.for_all
          ~f:(fun { File.digest; _ } -> Path.exists (file_path cache digest))
          files
      then
        default_trim
      else (
        cache.info
          [ Pp.textf
              "remove metadata file %s as some produced files are missing"
              (Path.to_string_maybe_quoted p)
          ];
        let res =
          List.fold_left ~init:default_trim
            ~f:(fun trim f ->
              let path_in_cache = file_path cache f.File.digest in
              try
                let stats = Path.stat path_in_cache in
                if trimmable stats then (
                  Path.unlink_no_err path_in_cache;
                  Trimming_result.add trim ~file:path_in_cache
                    ~size:stats.st_size
                ) else
                  trim
              with Unix.Unix_error (Unix.ENOENT, _, _) -> trim)
            files
        in
        Path.unlink_no_err p;
        res
      )
  in
  List.fold_left ~init:default_trim ~f metas

let garbage_collect = _garbage_collect Trimming_result.empty

let trim cache free =
  let root = file_store_root cache in
  let files = FSSchemeImpl.list ~root in
  let f path =
    let stats = Path.stat path in
    if trimmable stats then
      Some (path, stats.st_size, stats.st_mtime)
    else
      None
  and compare (_, _, t1) (_, _, t2) = Ordering.of_int (Stdlib.compare t1 t2) in
  let files = List.sort ~compare (List.filter_map ~f files)
  and delete (trim : Trimming_result.t) (path, size, _) =
    if trim.trimmed_files_size >= free then
      trim
    else (
      Path.unlink path;
      Trimming_result.add trim ~size ~file:path
    )
  in
  let trim = List.fold_left ~init:Trimming_result.empty ~f:delete files in
  _garbage_collect trim cache

let overhead_size cache =
  let root = file_store_root cache in
  let files = FSSchemeImpl.list ~root in
  let stats =
    let f p =
      try
        let stats = Path.stat p in
        if trimmable stats then
          stats.st_size
        else
          0
      with Unix.Unix_error (Unix.ENOENT, _, _) -> 0
    in
    List.map ~f files
  in
  List.fold_left ~f:(fun acc size -> acc + size) ~init:0 stats
