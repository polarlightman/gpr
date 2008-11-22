open Format

open Lacaml.Impl.D
open Lacaml.Io

open Gpr
open Utils

open Fitc

let n_inputs = 500
let n_inducing_inputs = 10
let k = -0.5, -0.5
let noise_sigma = 2.
let noise_sigma2 = noise_sigma *. noise_sigma

module FITC_spec = struct
  module Kernel = Kernel.Gauss

  let get_sigma2 _ = noise_sigma2
  let jitter = 10e-9
end

module All = Fitc.Make (FITC_spec)
open All

let f ?(with_noise = false) x =
  let v = 2. *. sin x /. x +. (x -. 3.) /. (x *. x +. 1.) in
  if with_noise then v +. Gsl_randist.gaussian default_rng ~sigma:noise_sigma
  else v

let get_data ?with_noise n =
  let inputs = Mat.create 1 n in
  let targets = Vec.create n in
  for i = 1 to n do
    let x = Random.float 10. -. 5. in
    inputs.{1, i} <- x;
    targets.{i} <- f ?with_noise x;
  done;
  inputs, targets

let get_training () =
  let training_inputs, training_targets = get_data ~with_noise:true n_inputs in
  write_float "sigma2" noise_sigma2;
  write_mat "inputs" training_inputs;
  write_vec "targets" training_targets;
  let inducing_inputs = Mat.create 1 n_inducing_inputs in
  for i = 1 to n_inducing_inputs do
    inducing_inputs.{1, i} <-
      -5. +. float i *. 10. /. float (n_inducing_inputs + 1)
  done;
  write_mat "inducing_inputs" inducing_inputs;
  training_inputs, training_targets, inducing_inputs

let main () =
  let training_inputs, training_targets, inducing_inputs = get_training () in
  let inducing = FITC.Inducing.calc k inducing_inputs in
  let reduceds = FITC.Induceds.calc inducing training_inputs in
  let model = FITC.Model.calc reduceds in
  let trained = FITC.Trained.calc model ~targets:training_targets in
  printf "neg_log_likelihood: %.3f@." (FITC.Trained.neg_log_likelihood trained);
  let weights = FITC.Weights.calc trained in
  let means = FITC.Means.calc_inputs weights model in
  let inducing_means =
    FITC.Means.copy (FITC.Means.calc_inducing weights model)
  in
  write_vec "inducing_means" inducing_means;
  let means_vec = FITC.Means.copy means in
  write_vec "means" means_vec;
  let variances =
    FITC.Variances.copy ~predictive:false (FITC.Variances.calc_inputs model)
  in
  write_vec "variances" variances;
  let covariances = FITC.Covariances.calc_inputs model in
  let samplers = FITC.Samplers.calc ~predictive:false means covariances in
  write_vec "sample1" (FITC.Samplers.sample samplers);
  write_vec "sample2" (FITC.Samplers.sample samplers);
  write_vec "sample3" (FITC.Samplers.sample samplers);
  let fic_covariances = FIC.Covariances.calc_inputs model in
  let fic_samplers = FIC.Samplers.calc ~predictive:false means fic_covariances in
  write_vec "fic_sample1" (FIC.Samplers.sample fic_samplers);
  write_vec "fic_sample2" (FIC.Samplers.sample fic_samplers);
  write_vec "fic_sample3" (FIC.Samplers.sample fic_samplers)

let () = main ()
