open Format

open Lacaml.Impl.D
open Lacaml.Io

open Gpr
open Utils

open Test_kernels.SE_iso
open Gen_data

let test_log_ell () =
  let sigma2 = noise_sigma2 in

  let epsilon = 1e-6 in

  let module Eval = FITC.Eval in
  let module Deriv = FITC.Deriv in
  let eval_inducing_prep =
    Eval.Inducing.Prepared.choose_n_random_inputs
      kernel ~n_inducing training_inputs
  in
  let deriv_inducing_prep = Deriv.Inducing.Prepared.calc eval_inducing_prep in
  let inducing = Deriv.Inducing.calc kernel deriv_inducing_prep in
  let eval_inputs_prep =
    Eval.Inputs.Prepared.calc eval_inducing_prep training_inputs
  in
  let deriv_inputs_prep =
    Deriv.Inputs.Prepared.calc deriv_inducing_prep eval_inputs_prep
  in
  let inputs = Deriv.Inputs.calc inducing deriv_inputs_prep in
  let model = Deriv.Model.calc ~sigma2 inputs in

  let new_kernel =
    let params = Eval.Spec.Kernel.get_params kernel in
    let new_log_ell = params.Cov_se_iso.Params.log_ell +. epsilon in
    let new_params =
      { params with Cov_se_iso.Params.log_ell = new_log_ell }
    in
    Eval.Spec.Kernel.create new_params
  in

  let inducing2 = Deriv.Inducing.calc new_kernel deriv_inducing_prep in
  let inputs2 = Deriv.Inputs.calc inducing2 deriv_inputs_prep in
  let model2 = Deriv.Model.calc ~sigma2 inputs2 in

  let hyper_model = Deriv.Model.prepare_hyper model in
  let dmev = Deriv.Model.calc_log_evidence hyper_model `Log_ell in

  let mf1 = Eval.Model.calc_log_evidence (Deriv.Model.calc_eval model) in
  let mf2 = Eval.Model.calc_log_evidence (Deriv.Model.calc_eval model2) in

  print_float "model log evidence" mf1;
  print_float "derivative of model log evidence" dmev;
  print_float "model log evidence finite diff" ((mf2 -. mf1) /. epsilon);

  let trained = Deriv.Trained.calc model ~targets:training_targets in
  let trained2 = Deriv.Trained.calc model2 ~targets:training_targets in

  let hyper_trained = Deriv.Trained.prepare_hyper trained in
  let dev = Deriv.Trained.calc_log_evidence hyper_trained `Log_ell in

  let f1 = Eval.Trained.calc_log_evidence (Deriv.Trained.calc_eval trained) in
  let f2 = Eval.Trained.calc_log_evidence (Deriv.Trained.calc_eval trained2) in

  print_float "trained model log evidence" f1;
  print_float "derivative of trained model log evidence" dev;
  print_float "trained model finite diff" ((f2 -. f1) /. epsilon)

let test_inducing () =
  Lacaml.Io.Context.set_dim_defaults (Some (Context.create 5));

  let sigma2 = noise_sigma2 in

  let epsilon = 1e-6 in

  let module Eval = FITC.Eval in
  let module Deriv = FITC.Deriv in

  let inducing_inputs =
    let training_inputs = lacpy ~n:3 training_inputs in
    Eval.Spec.Inputs.create_inducing kernel training_inputs
  in

  let run () =
    let eval_inducing_prep = Eval.Inducing.Prepared.calc inducing_inputs in
    let deriv_inducing_prep = Deriv.Inducing.Prepared.calc eval_inducing_prep in
    let inducing = Deriv.Inducing.calc kernel deriv_inducing_prep in
    let eval_inputs_prep =
      Eval.Inputs.Prepared.calc eval_inducing_prep training_inputs
    in
    let deriv_inputs_prep =
      Deriv.Inputs.Prepared.calc deriv_inducing_prep eval_inputs_prep
    in
    let inputs = Deriv.Inputs.calc inducing deriv_inputs_prep in
    let model = Deriv.Model.calc ~sigma2 inputs in

    let hyper_model = Deriv.Model.prepare_hyper model in
    let dmev =
      Deriv.Model.calc_log_evidence hyper_model
        (`Inducing_hyper { Cov_se_iso.ind = 3; dim = 1 })
    in

    let mf = Eval.Model.calc_log_evidence (Deriv.Model.calc_eval model) in
    dmev, mf
  in

  let mev, mf1 = run () in
  inducing_inputs.{1, 3} <- inducing_inputs.{1, 3} +. epsilon;
  let _, mf2 = run () in

  print_float "inducing mdlog_evidence" mev;
  print_float "inducing mdfinite" ((mf2 -. mf1) /. epsilon)

let main () =
  test_log_ell ();
  test_inducing ()

let () = main ()
