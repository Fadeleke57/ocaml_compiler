(* UTILITIES *)
let cons x xs = x :: xs
let explode s = List.of_seq (String.to_seq s)
let implode cs = String.of_seq (List.to_seq cs)
let is_digit c = '0' <= c && c <= '9'
let is_blank c = String.contains " \012\n\r\t" c
let is_upper_case c = 'A' <= c && c <= 'Z'
let is_lower_case c = 'a' <= c && c <= 'z'
let is_alphanum c = is_lower_case c || is_digit c

type 'a parser = char list -> ('a * char list) option

let satisfy f = function
  | c :: cs when f c -> Some (c, cs)
  | _ -> None

let char c = satisfy ((=) c)

let str s cs =
  let rec go = function
    | [], ds -> Some (s, ds)
    | c :: cs, d :: ds when c = d -> go (cs, ds)
    | _ -> None
  in go (explode s, cs)

let map f p cs =
  match p cs with
  | Some (x, cs) -> Some (f x, cs)
  | None -> None

let (>|=) p f = map f p
let (>|) p x = map (fun _ -> x) p

let seq p1 p2 cs =
  match p1 cs with
  | Some (x, cs) -> (
      match p2 cs with
      | Some (y, cs) -> Some ((x, y), cs)
      | None -> None
    )
  | None -> None

let (<<) p1 p2 = map fst (seq p1 p2)
let (>>) p1 p2 = map snd (seq p1 p2)

let map2 f p1 p2 =
  seq p1 p2 >|= fun (x, y) -> f x y

let optional p cs =
  match p cs with
  | Some (x, cs) -> Some (Some x, cs)
  | None -> Some (None, cs)

let rec many p cs =
  match p cs with
  | Some (x, cs) -> (
      match (many p cs) with
      | Some (xs, cs) -> Some (x :: xs, cs)
      | None -> Some ([x], cs)
    )
  | None -> Some ([], cs)

let many1 p = map2 cons p (many p)

let alt p1 p2 cs =
  match p1 cs with
  | Some x -> Some x
  | None ->
    match p2 cs with
    | Some x -> Some x
    | None -> None

let (<|>) = alt

let pure x cs = Some (x, cs)
let fail _ = None

let bind p f cs =
  match p cs with
  | Some (x, cs) -> f x cs
  | None -> None

let (>>=) = bind
let ( let* ) = bind

let choice ps =
  List.fold_left (<|>) fail ps

let chainl1' p op =
  map2
    (List.fold_left (fun x opy -> opy x))
    (pure () >>= p)
    (many1 (map2 (fun f y x -> f x y) op (pure () >>= p)))

let parse_comment =
  let not_closing cs =
    match cs with
    | '*' :: ')' :: cs -> None
    | _ :: cs -> Some ((), cs)
    | [] -> None
  in
  str "(*" >> many not_closing  >> str "*)" >| ()

let ws = many (satisfy is_blank) >| ()
let ws = many (ws >> parse_comment) >> ws
let keyword w = str w << ws

let parse p s =
  match p (explode s) with
  | Some (x, []) -> Some x
  | _ -> None

(* END OF UTILITIES *)

(* HIGH-LEVEL-SYNTAX PARSING *)

type ident = string

type uop
  = Neg | Not
type bop
  = Add | Sub | Mul | Div
  | And | Or
  | Lt  | Lte | Gt | Gte | Eq |Neq

type expr
  = Unit
  | Num of int
  | Bool of bool
  | Var of ident
  | Uop of uop * expr
  | Bop of bop * expr * expr
  | Fun of ident list * expr
  | App of expr * expr
  | Let of ident * ident list * expr * expr
  | Ife of expr * expr * expr
  | Trace of expr

type top_prog = (ident * ident list * expr) list

let parse_nat =
  many1 (satisfy is_digit)
  >|= fun cs -> int_of_string (implode cs)

let parse_bool =
  (str "true" >| true)
  <|> (str "false" >| false)

let parse_unit =
  str "()" >| Unit

let parse_ident =
  many1 (satisfy (fun c -> c = '_' || is_alphanum c))
  >|= implode

let is_reserved s =
  List.mem s
    [ "not"
    ; "let"
    ; "in"
    ; "fun"
    ; "true"
    ; "false"
    ; "if"
    ; "then"
    ; "else"
    ; "trace"
    ]

let parse_var =
  let* i = parse_ident in
  if is_reserved i
  then fail
  else pure (Var i)

let parse_fun p =
  let* _ = keyword "fun" in
  let* xs = many1 (parse_ident << ws) in
  let* _ = keyword "->" in
  let* body = p () in
  pure (Fun (xs, body))

let parse_let p =
  let* _ = keyword "let" in
  let* f = parse_ident << ws in
  let* xs = many (parse_ident << ws) in
  let* _ = keyword "=" in
  let* v = p () << ws in
  let* _ = keyword "in" in
  let* e = p () in
  pure (Let (f, xs, v, e))

let parse_ife p =
  let* _ = keyword "if" in
  let* b = p () << ws in
  let* _ = keyword "then" in
  let* l = p () << ws in
  let* _ = keyword "else" in
  let* r = p () in
  pure (Ife (b, l, r))

let parse_uop w u =
  keyword w >| (fun x -> Uop (u, x))

let parse_bop w b =
  ws >> keyword w >| (fun x y -> Bop (b, x, y))

let parse_op_2 =
  parse_bop "||" Or

let parse_op_3 =
  parse_bop "&&" And

let parse_op_4 =
  choice
    [ parse_bop "<=" Lte
    ; parse_bop "<>" Neq
    ; parse_bop "<" Lt
    ; parse_bop ">=" Gte
    ; parse_bop ">" Gt
    ; parse_bop "=" Eq
    ]

let parse_op_5 =
  choice
    [ parse_bop "+" Add
    ; parse_bop "-" Sub
    ]

let parse_op_6 =
  choice
    [ parse_bop "*" Mul
    ; parse_bop "/" Div
    ]

let parse_op_7 =
  choice
    [ parse_uop "-" Neg
    ; parse_uop "not" Not
    ]

let unop op p =
  let* f = op in
  let* x = p () in
  pure (f x)

let binop op p =
  let* x = p () in
  let* f = op in
  let* y = p () in
  pure (f x y)

let parse_app p =
  chainl1' p (ws >| fun x y -> App (x, y))

let parse_trace p =
  let* _ = keyword "trace" in
  let* x = p () in
  pure (Trace x)

let parse_expr =
  let rec parse_expr_1 () =
    choice
      [ parse_fun parse_expr_1
      ; parse_let parse_expr_1
      ; parse_ife parse_expr_1
      ; parse_expr_2 ()
      ]
  and parse_expr_2 () =
    binop parse_op_2 parse_expr_3
    <|> parse_expr_3 ()
  and parse_expr_3 () =
    chainl1' parse_expr_4 parse_op_3
    <|> parse_expr_4 ()
  and parse_expr_4 () =
    chainl1' parse_expr_5 parse_op_4
    <|> parse_expr_5 ()
  and parse_expr_5 () =
    chainl1' parse_expr_6 parse_op_5
    <|> parse_expr_6 ()
  and parse_expr_6 () =
    chainl1' parse_expr_7 parse_op_6
    <|> parse_expr_7 ()
  and parse_expr_7 () =
    unop parse_op_7 parse_expr_8
    <|> parse_expr_8 ()
  and parse_expr_8 () =
    parse_trace parse_expr_9
    <|> parse_app parse_expr_9
    <|> parse_expr_9 ()
  and parse_expr_9 () =
    choice
      [ parse_nat >|= (fun n -> Num n)
      ; parse_bool >|= (fun b -> Bool b)
      ; parse_unit
      ; parse_var
      ; keyword "(" >> (pure () >>= parse_expr_1) << keyword ")"
      ]
  in parse_expr_1 ()

let parse_top_prog =
  let parse_let_def =
    let* _ = keyword "let" in
    let* f = parse_ident << ws in
    let* xs = many (parse_ident << ws) in
    let* _ = keyword "=" in
    let* e = parse_expr in
    pure (f, xs, e)
  in many (parse_let_def << ws)

let parse_top_prog = parse (ws >> parse_top_prog)

(* END OF HIGH-LEVEL SYNTAX PARSING *)

(* STACK-BASED LANGUAGE *)

let ws = many (satisfy is_blank) >| ()
let keyword w = str w << ws

type const
  = Num of int
  | Bool of bool
  | Unit

type value
  = Const of const
  | Clos of
      { name : ident
      ; captured : bindings
      ; body : stack_prog
      }

and bindings = (ident * value) list
and stack_prog = command list

and command
  = Push of const | Swap | Trace
  | Add | Sub | Mul | Div | Lt
  | If of stack_prog * stack_prog
  | Fun of ident * stack_prog | Call | Return
  | Assign of ident | Lookup of ident

let parse_cap_ident =
  many1 (satisfy is_upper_case)
  >|= implode

let parse_const =
  (parse_nat >|= fun x -> Num x)
  <|> (parse_bool >|= fun b -> Bool b)
  <|> (str "unit" >| Unit)

let rec parse_command () =
  let parse_if =
    let* _ = keyword "if" in
    let* p = parse_stack_prog () in
    let* _ = keyword "else" in
    let* q = parse_stack_prog () in
    let* _ = str "end" in
    pure (If (p, q))
  in
  let parse_fun =
    let* _ = keyword "fun" in
    let* name = parse_cap_ident << ws in
    let* _ = keyword "begin" in
    let* body = parse_stack_prog () in
    let* _ = keyword "end" in
    pure (Fun (name, body))
  in
  let parse_push =
    keyword "push"
    >> parse_const
    >|= (fun c -> Push c)
  in
  let parse_assign =
    keyword "assign"
    >> parse_cap_ident
    >|= (fun i -> Assign i)
  in
  let parse_lookup =
    keyword "lookup"
    >> parse_cap_ident
    >|= (fun i -> Lookup i)
  in
  choice
    [ str "swap"  >| Swap
    ; str "trace" >| Trace
    ; str "add"   >| Add
    ; str "sub"   >| Sub
    ; str "mul"   >| Mul
    ; str "div"   >| Div
    ; str "lt"    >| Lt
    ; str "call"  >| Call
    ; str "return" >| Return
    ; parse_if
    ; parse_fun
    ; parse_push
    ; parse_assign
    ; parse_lookup
    ]
and parse_stack_prog () =
  many ((pure () >>= parse_command) << ws)
let parse_stack_prog = parse (ws >> parse_stack_prog ())

(* END OF PARSING *)

(* EVALUTION *)

let to_string v =
  match v with
  | Const (Num n) -> string_of_int n
  | Const (Bool true) -> "true"
  | Const (Bool false) -> "false"
  | Const Unit -> "unit"
  | Clos _ -> "<function>"

let rec update e x v = (x, v) :: e
let rec fetch e x =
  match e with
  | [] -> None
  | (y, v) :: _ when x = y -> Some v
  | _ :: e -> fetch e x

let panic (s, e, t, p) = ([], [], "panic" :: t, [])

let eval_step c =
  match c with
  (* push *)
  | s, e, t, Push c :: p ->
    Const c :: s, e, t, p
  (* swap *)
  | x :: y :: s, e, t, Swap :: p ->
    y :: x :: s, e, t, p
  (* trace *)
  | v :: s, e, t, Trace :: p ->
    s, e, to_string v :: t, p
  (* add *)
  | Const (Num x) :: Const (Num y) :: s, e, t, Add :: p ->
    Const (Num (x + y)) :: s, e, t, p
  (* sub *)
  | Const (Num x) :: Const (Num y) :: s, e, t, Sub :: p ->
    Const (Num (x - y)) :: s, e, t, p
  (* mul *)
  | Const (Num x) :: Const (Num y) :: s, e, t, Mul :: p ->
    Const (Num (x * y)) :: s, e, t, p
  (* div *)
  | Const (Num x) :: Const (Num y) :: s, e, t, Div :: p when y <> 0 ->
    Const (Num (x / y)) :: s, e, t, p
  (* lt *)
  | Const (Num x) :: Const (Num y) :: s, e, t, Lt :: p ->
    Const (Bool (x < y)) :: s, e, t, p
  (* if *)
  | Const (Bool b) :: s, e, t, If (q1, q2) :: p ->
    s, e, t, (if b then q1 else q2) @ p
  (* fun *)
  | s, e, t, Fun (name, body) :: p ->
    Clos {name; body; captured = e} :: s, e, t, p
  (* call *)
  | Clos c :: s, e, t, Call :: p ->
    Clos {name = "cc"; captured = e; body = p} :: s,
    update c.captured c.name (Clos c),
    t, c.body
  (* return *)
  | Clos c :: s, e, t, Return :: p ->
    s, c.captured, t, c.body
  (* assign *)
  | Clos c :: s, e, t, Assign x :: p ->
    s, update e x (Clos { c with name = x }), t, p
  | v :: s, e, t, Assign x :: p ->
    s, update e x v, t, p
  (* lookup *)
  | s, e, t, Lookup x :: p -> (
      match fetch e x with
      | None -> panic c
      | Some v -> v :: s, e, t, p
    )
  (* panic *)
  | _ -> panic c

let eval_stack_prog p =
  let rec go c =
    match c with
    | _, _, t, [] -> t
    | c -> go (eval_step c)
  in go ([], [], [], p)

let interp p =
  Option.map
    eval_stack_prog
    (parse_stack_prog p)

(* END OF EVALUATION *)

(* END OF STACK-BASED LANGUAGE *)

(* END OF PROVIDED CODE *)

(* ============================================================ *)

(*  PROJECT 3 *)

type lexpr
  = Num of int
  | Bool of bool
  | Unit
  | Var of ident
  | Uop of uop * lexpr
  | Bop of bop * lexpr * lexpr
  | Ife of lexpr * lexpr * lexpr
  | Fun of ident * lexpr
  | App of lexpr * lexpr
  | Trace of lexpr

let rec expr_to_lexpr (e : expr) : lexpr =
  match e with
  | Unit -> Unit
  | Num n -> Num n
  | Bool b -> Bool b
  | Var x -> Var x
  | Uop (op, e) -> Uop (op, expr_to_lexpr e)
  | Bop (op, e1, e2) -> Bop (op, expr_to_lexpr e1, expr_to_lexpr e2)
  | Fun (args, e) -> List.fold_right (fun arg body -> Fun (arg, body)) args (expr_to_lexpr e)
  | App (e1, e2) -> App (expr_to_lexpr e1, expr_to_lexpr e2)
  | Let (x, args, e1, e2) -> App (Fun (x, expr_to_lexpr e2), List.fold_right (fun arg body -> Fun (arg, body)) args (expr_to_lexpr e1))
  | Ife (e1, e2, e3) -> Ife (expr_to_lexpr e1, expr_to_lexpr e2, expr_to_lexpr e3)
  | Trace e -> Trace (expr_to_lexpr e)

let rec desugar_fun_defs defs =
  match defs with
  | [] -> Unit
  | (f, args, expr) :: rest -> let nested_fun = List.fold_right (fun arg body -> Fun (arg, body)) args (expr_to_lexpr expr) in App (Fun (f, desugar_fun_defs rest), nested_fun)

let desugar (p : top_prog) : lexpr = (*main*)
  desugar_fun_defs p

(*
let Some p = (parse_top_prog "let x = trace 10") 
let _ = assert (desugar p = App(Fun ("x", Unit), Trace (Num 10)))

let Some p = (parse_top_prog "let k x y = x let _ = trace (k 5 10)") 
let _ = assert (desugar p = App(Fun ("k", App (Fun ("_", Unit), Trace (App (App (Var "k", Num 5), Num 10)))), Fun ("x", Fun ("y", Var "x"))))

let Some p = parse_top_prog "let _ = let _ = trace 10 in 10"
let _ = assert (desugar p = App (Fun ("_", Unit), App (Fun ("_", Num 10), Trace (Num 10))))
*)
 
let check_int = [Push (Num 0); Add]

let rec translate (e : lexpr) : stack_prog =
  match e with
  (*Base Values*)
  | Num n -> [Push (Num n)]
  | Bool b -> [Push (Bool b)]
  | Unit -> [Push Unit]
  (*Trace*)
  | Trace e -> translate e @ [Trace; Push Unit]
  (*Binary arithmetic ops*)
  | Bop (Add, e1, e2) -> translate e2 @ check_int @ translate e1 @ [Add]
  | Bop (Sub, e1, e2) -> translate e2 @ check_int @ translate e1 @ [Sub]
  | Bop (Mul, e1, e2) -> translate e2 @ check_int @ translate e1 @ [Mul]
  | Bop (Div, e1, e2) -> translate e2 @ check_int @ translate e1 @ [Div]  
  (*Negate*)
  | Uop (Neg, e) -> translate e @ [Push (Num 0); Sub]
  (*Not*)
  | Uop (Not, e) -> translate e @ [If ([Push (Bool false)],[Push (Bool true)])] 
  (*Less Than*)
  | Bop (Lt, e1, e2) -> translate e2 @ check_int @ translate e1 @ [Lt]
  (*Less Than or Equal*)
  | Bop (Lte, e1, e2) -> translate e2 @ check_int @ translate e1 @ [Swap; Lt; If ([Push (Bool false)],[Push (Bool true)])]
  (*Greater Than*)
  | Bop (Gt, e1, e2) -> translate e2 @ check_int @ translate e1 @ [Swap; Lt]
  (*Greater Than or Equal*)
  | Bop (Gte, e1, e2) -> translate e2 @ check_int @ translate e1 @ [Lt; If ([Push (Bool false)],[Push (Bool true)])]
  (*Equal*)
  | Bop (Eq, e1, e2) -> let exp2 = translate e2 in let exp1 = translate e1 in 
    (match exp2, exp1 with
    | [Push (Num m)], [Push (Num n)] -> exp2 @ exp1 @ [Swap; Lt; If ([Push (Bool false)],[Push (Num m); Push (Num n); Lt; If ([Push (Bool false)],[Push (Bool true)])])]
    | _ -> exp2 @ check_int @ exp1 @ check_int
    ) 
  (*Not Equal*)                                                                                       
  | Bop (Neq, e1, e2) -> let exp2 = translate e2 in let exp1 = translate e1 in 
    (match exp2, exp1 with
    | [Push (Num m)], [Push (Num n)] -> exp2 @ exp1 @ [Swap; Lt; If ([Push (Bool true)],[Push (Num m); Push (Num n); Lt; If ([Push (Bool true)],[Push (Bool false)])])]
    | _ -> exp2 @ check_int @ exp1 @ check_int
    ) 
  (*And*)
  | Bop (And, e1, e2) ->
    let exp1 = translate e1 in 
    (match exp1 with
    | [Push (Bool false)] -> [Push (Bool false)] (*short circuit when first is false*)
    | [Push (Bool true)] -> (
      let exp2 = translate e2 in
        match exp2 with
        | [Push (Bool true)] -> [Push (Bool true)] (*both true*)
        | [Push (Bool false)] -> [Push (Bool false)] (*first is true second is false*)
        | _ -> exp2 @ [If([],[])] (*will panic bc non-boolean*)
        )
    | _ -> exp1 @ [If([],[])] (*will panic bc non-boolean*)
    )
  (*Or*)
  | Bop (Or, e1, e2) ->
    let exp1 = translate e1 in  
    (match exp1 with
    | [Push (Bool true)] -> [Push (Bool true)] (*short circuit when first is false*)
    | [Push (Bool false)] -> (
      let exp2 = translate e2 in
        match exp2 with
        | [Push (Bool true)] -> [Push (Bool true)] (*first is false second is true*)
        | [Push (Bool false)] -> [Push (Bool false)] (*both false*)
        | _ -> exp2 @ [If([],[])] (*will panic bc non-boolean*)
        )
    | _ -> exp1 @ [If([],[])] (*will panic bc non-boolean*)
    )  
  (*If else*)
  | Ife (cond, thn, els) -> translate cond @ [If (translate thn, translate els)]
  (*Function Application*)
  | App (f, arg) -> translate arg @ translate f @ [Call]
  | Var x -> [Lookup x]
  | Fun (arg, body) -> [Fun (arg, [Swap; Assign arg] @ translate body @ [Swap; Return])]

let rec assign_name (id : char list) (acc : string) : string =
  match id with
  | [] -> acc
  | '_' :: rest -> assign_name rest (acc ^ "BK")
  | id' :: rest -> assign_name rest (acc ^ "A" ^ (String.make 1 (Char.chr ((Char.code id') - 32)))) 

let indent level = String.make (level * 4) ' '  (* 4 spaces per indentation level *)

let rec serialize ?(level=0) (p : stack_prog) : string =
  List.fold_left (fun acc cmd ->
    acc ^ "\n" ^ (indent level) ^
    (match cmd with
      | Push (Num n) -> "push " ^ string_of_int n
      | Push (Bool b) -> "push " ^ (if b then "true" else "false")
      | Push Unit -> "push unit"
      | Lookup x -> "lookup " ^ (assign_name (explode x) "")
      | Trace -> "trace"
      | Add -> "add"
      | Sub -> "sub"
      | Mul -> "mul"
      | Div -> "div"
      | Lt -> "lt"
      | If (p1, p2) -> "if" ^ serialize ~level:(level+1) p1 ^ "\n" ^ (indent level) ^ "else" ^ serialize ~level:(level+1) p2 ^ "\n" ^ (indent level) ^ "end"
      | Fun (arg, p) -> "fun C begin" ^  serialize ~level:(level+1) p ^ "\n" ^ (indent level) ^ "end"
      | Call -> "call"
      | Return -> "return"
      | Assign x -> "assign " ^ (assign_name (explode x) "")
      | Swap -> "swap"
    )
  ) "" p

let compile (s : string) : string option =
  match parse_top_prog s with
  | Some p -> Some (serialize (translate (desugar p)))
  | None -> None

(* ============================================================ *)

(* END OF FILE *)
