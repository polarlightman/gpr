open Lacaml.Impl.D

open Utils
open Interfaces
open Inducing_input_gpr

(* TODO: dimension sanity checks *)
(* TODO: consistency checks; also finite differences *)

module type Sig = functor (Spec : Specs.Eval) ->
  Sigs.Eval with module Spec = Spec

module Make_common (Spec : Specs.Eval) = struct
  module Spec = Spec

  open Spec

  let jitter = !cholesky_jitter

  module Inducing = struct
    type t = {
      kernel : Kernel.t;
      points : Spec.Inducing.t;
      km : mat;
      km_chol : mat;
      log_det_km : float;
    }

    let calc_internal kernel points km =
      (* TODO: copy upper triangle only *)
      let km_chol = Mat.copy km in
      potrf ~jitter km_chol;
      let log_det_km = log_det km_chol in
      {
        kernel = kernel;
        points = points;
        km = km;
        km_chol = km_chol;
        log_det_km = log_det_km;
      }

    let calc kernel points =
      let km = Spec.Inducing.upper kernel points in
      calc_internal kernel points km

    let get_kernel inducing = inducing.kernel
  end

  module Input = struct
    type t = {
      inducing : Inducing.t;
      point : Spec.Input.t;
      k_m : vec;
    }

    let calc inducing point =
      let kernel = inducing.Inducing.kernel in
      {
        inducing = inducing;
        point = point;
        k_m =
          Spec.Input.eval
            kernel ~inducing:inducing.Inducing.points ~input:point;
      }

    let get_kernel t = t.inducing.Inducing.kernel
  end

  let calc_basis_2_k basis_chol ~k =
    (* TODO: consider symmetric matrices *)
    let b_2_k = Mat.copy k in
    trtrs ~trans:`T basis_chol b_2_k;
    b_2_k

  module Inputs = struct
    type t = {
      inducing : Inducing.t;
      points : Inputs.t;
      kmn : mat;
    }

    let calc_internal inducing points kmn =
      {
        inducing = inducing;
        points = points;
        kmn = kmn;
      }

    let calc inducing points =
      let kernel = inducing.Inducing.kernel in
      let kmn =
        Inputs.cross kernel ~inducing:inducing.Inducing.points ~inputs:points
      in
      calc_internal inducing points kmn

    let get_kernel t = t.inducing.Inducing.kernel
    let get_inducing_points t = t.inducing.Inducing.points

    (* Compute square root of Nystrom approximation, cross gramian,
       and the diagonal of marginal variances *)
    let nystrom_2_marginals inputs =
      let inducing = inputs.inducing in
      let kernel = get_kernel inputs in
      let kn_diag = Inputs.diag kernel inputs.points in
      let km_2_kmn = calc_basis_2_k inducing.Inducing.km_chol ~k:inputs.kmn in
      km_2_kmn, kn_diag
  end

  module Common_model = struct
    type t = {
      inputs : Inputs.t;
      kn_diag : vec;
      km_2_kmn : mat;
      lam_diag : vec;
      inv_lam_sigma2_diag : vec;
      b_chol : mat;
      evidence : float;
    }

    let calc_internal inputs km_2_kmn kn_diag =
      let inducing = inputs.Inputs.inducing in
      let kernel = Inputs.get_kernel inputs in
      let sigma2 = Kernel.get_sigma2 kernel in
      let kmn = inputs.Inputs.kmn in
      let kmn_= Mat.copy kmn in
      let n_inputs = Vec.dim kn_diag in
      let lam_diag = Vec.create n_inputs in
      let inv_lam_sigma2_diag = Vec.create n_inputs in
      let rec loop log_det_lam_sigma2 i =
        if i = 0 then log_det_lam_sigma2
        else
          let kn_diag_i = kn_diag.{i} in
          (* TODO: optimize ssqr and col *)
          let qn_diag_i = Vec.ssqr (Mat.col km_2_kmn i) in
          let lam_i = kn_diag_i -. qn_diag_i in
          lam_diag.{i} <- lam_i;
          let lam_sigma2_i = lam_i +. sigma2 in
          let inv_lam_sigma2_i = 1. /. lam_sigma2_i in
          inv_lam_sigma2_diag.{i} <- inv_lam_sigma2_i;
          (* TODO: optimize scal col *)
          scal (sqrt inv_lam_sigma2_i) (Mat.col kmn_ i);
          loop (log_det_lam_sigma2 +. log lam_sigma2_i) (i - 1)
      in
      let log_det_lam_sigma2 = loop 0. n_inputs in
      (* TODO: copy upper triangle only *)
      let b_chol = syrk kmn_ ~beta:1. ~c:(Mat.copy inducing.Inducing.km) in
      potrf ~jitter b_chol;
      let log_det_km = inducing.Inducing.log_det_km in
      let log_det_b = log_det b_chol in
      let l1_2 = log_det_km -. log_det_b -. log_det_lam_sigma2 in
      {
        inputs = inputs;
        kn_diag = kn_diag;
        km_2_kmn = km_2_kmn;
        lam_diag = lam_diag;
        inv_lam_sigma2_diag = inv_lam_sigma2_diag;
        b_chol = b_chol;
        evidence = 0.5 *. (l1_2 -. float n_inputs *. log_2pi);
      }

    let calc inputs =
      let km_2_kmn, kn_diag = Inputs.nystrom_2_marginals inputs in
      calc_internal inputs km_2_kmn kn_diag

    let calc_evidence model = model.evidence
    let get_inducing model = model.inputs.Inputs.inducing
    let get_inducing_points model = (get_inducing model).Inducing.points
    let get_input_points model = model.inputs.Inputs.points
    let get_kernel model = (get_inducing model).Inducing.kernel
    let get_sigma2 model = Kernel.get_sigma2 (get_kernel model)
    let get_kmn model = model.inputs.Inputs.kmn
    let get_lam_diag model = model.lam_diag
    let get_km model = (get_inducing model).Inducing.km
  end

  module Variational_model = struct
    include Common_model

    let calc inputs =
      let
        {
          lam_diag = lam_diag;
          inv_lam_sigma2_diag = x;
          evidence = evidence;
        } as model = calc inputs
      in
      { model with evidence = evidence +. 0.5 *. dot ~x lam_diag }
  end

  module Trained = struct
    type t = {
      model : Common_model.t;
      inv_b_chol_kmn_y__ : vec;
      evidence : float;
    }

    let calc model ~targets =
      let n_targets = Vec.dim targets in
      let y__ = Vec.create n_targets in
      let inv_lam_sigma2_diag = model.Common_model.inv_lam_sigma2_diag in
      for i = 1 to n_targets do
        y__.{i} <- targets.{i} *. inv_lam_sigma2_diag.{i}
      done;
      let kmn = Common_model.get_kmn model in
      let inv_b_chol_kmn_y__ = gemv kmn y__ in
      let ssqr_y__ = dot ~x:targets y__ in
      let b_chol = model.Common_model.b_chol in
      trsv ~trans:`T b_chol inv_b_chol_kmn_y__;
      let fit_evidence = 0.5 *. (Vec.ssqr inv_b_chol_kmn_y__ -. ssqr_y__) in
      {
        model = model;
        inv_b_chol_kmn_y__ = inv_b_chol_kmn_y__;
        evidence = model.Common_model.evidence +. fit_evidence;
      }

    let calc_evidence trained = trained.evidence
  end

  module Weights = struct
    type t = { model : Common_model.t; coeffs : vec }

    let get_kernel weights = Common_model.get_kernel weights.model
    let get_inducing weights = Common_model.get_inducing weights.model

    let get_inducing_points weights =
      Common_model.get_inducing_points weights.model

    let get_coeffs weights = weights.coeffs

    let calc trained =
      let coeffs = copy trained.Trained.inv_b_chol_kmn_y__ in
      trsv trained.Trained.model.Common_model.b_chol coeffs;
      {
        model = trained.Trained.model;
        coeffs = coeffs;
      }
  end

  module Mean = struct
    type t = { point : Spec.Input.t; value : float }

    let make ~point ~value = { point = point; value = value }

    let calc_input weights point =
      let inducing_points = Weights.get_inducing_points weights in
      let kernel = Weights.get_kernel weights in
      let coeffs = Weights.get_coeffs weights in
      let value =
        Spec.Input.weighted_eval
          kernel ~coeffs ~inducing:inducing_points ~input:point
      in
      make ~point ~value

    let calc_induced weights input =
      if Weights.get_inducing weights <> input.Input.inducing then
        failwith
          "Fitc.Make_common.Mean.calc_induced: \
          weights and input disagree about inducing points";
      let value = dot ~x:input.Input.k_m weights.Weights.coeffs in
      make ~point:input.Input.point ~value

    let get m = m.value
  end

  module Means = struct
    type t = { points : Spec.Inputs.t; values : vec }

    let make ~points ~values = { points = points; values = values }

    let calc_model_inputs { Weights.coeffs = coeffs; model = model } =
      make
        ~points:(Common_model.get_input_points model)
        ~values:(gemv ~trans:`T (Common_model.get_kmn model) coeffs)

    let calc_inputs weights points =
      let kernel = Weights.get_kernel weights in
      let coeffs = Weights.get_coeffs weights in
      let inducing_points = Weights.get_inducing_points weights in
      let values =
        Spec.Inputs.weighted_eval
          kernel ~coeffs ~inducing:inducing_points ~inputs:points
      in
      make ~points ~values

    let calc_induced weights inputs =
      let { Inputs.points = points; kmn = kmn } = inputs in
      if Weights.get_inducing weights <> inputs.Inputs.inducing then
        failwith
          "Fitc.Make_common.Means.calc_induced: \
          weights and inputs disagree about inducing points";
      make ~points ~values:(gemv ~trans:`T kmn weights.Weights.coeffs)

    let get means = means.values

    module Inducing = struct
      type t = { points : Spec.Inducing.t; values : vec }

      let make ~points ~values = { points = points; values = values }

      let calc { Weights.coeffs = coeffs; model = model } =
        make
          ~points:(Common_model.get_inducing_points model)
          ~values:(symv (Common_model.get_km model) coeffs)

      let get means = means.values
    end
  end

  module Variance = struct
    type t = { point : Spec.Input.t; variance : float; sigma2 : float }

    let calc_induced model induced =
      let { Input.point = point; k_m = k_m } = induced in
      let kernel = Common_model.get_kernel model in
      let prior_variance = Spec.Input.eval_one kernel point in
      let inv_km_chol_k_m = copy k_m in
      let inv_km_chol_k_m_mat = Mat.from_col_vec inv_km_chol_k_m in
      let inducing = induced.Input.inducing in
      potrs ~factorize:false inducing.Inducing.km_chol inv_km_chol_k_m_mat;
      let km_arg = dot ~x:k_m inv_km_chol_k_m in
      let inv_b_chol_k_m = copy k_m ~y:inv_km_chol_k_m in
      let inv_b_chol_k_m_mat = inv_km_chol_k_m_mat in
      potrs ~factorize:false model.Common_model.b_chol inv_b_chol_k_m_mat;
      let b_arg = dot ~x:k_m inv_b_chol_k_m in
      let explained_variance = km_arg -. b_arg in
      let variance = prior_variance -. explained_variance in
      {
        point = point;
        variance = variance;
        sigma2 = Common_model.get_sigma2 model;
      }

    let get ?predictive t =
      match predictive with
      | None | Some true -> t.variance +. t.sigma2
      | Some false -> t.variance
  end

  let calc_b_2_k model ~k = calc_basis_2_k model.Common_model.b_chol ~k

  module Variances = struct
    type t = { points : Spec.Inputs.t; variances : vec; sigma2 : float }

    let make ~points ~variances ~model =
      let sigma2 = Common_model.get_sigma2 model in
      { points = points; variances = variances; sigma2 = sigma2 }

    let calc_model_inputs model =
      let variances = copy (Common_model.get_lam_diag model) in
      let b_2_kmn = calc_b_2_k model ~k:(Common_model.get_kmn model) in
      let n = Mat.dim2 b_2_kmn in
      for i = 1 to n do
        (* TODO: optimize ssqr and col *)
        variances.{i} <- variances.{i} +. Vec.ssqr (Mat.col b_2_kmn i)
      done;
      make ~points:(Common_model.get_input_points model) ~variances ~model

    let calc_induced model inputs =
      if Common_model.get_inducing model <> inputs.Inputs.inducing then
        failwith
          "Fitc.Make_common.Variances.calc_induced: \
          model and inputs disagree about inducing points";
      let kmt = inputs.Inputs.kmn in
      let km_2_kmt, kt_diag = Inputs.nystrom_2_marginals inputs in
      let variances = copy kt_diag in
      let b_2_kmt = calc_b_2_k model ~k:kmt in
      let n = Mat.dim2 b_2_kmt in
      for i = 1 to n do
        let explained_variance =
          (* TODO: optimize ssqr and col *)
          Vec.ssqr (Mat.col km_2_kmt i) -. Vec.ssqr (Mat.col b_2_kmt i)
        in
        variances.{i} <- variances.{i} -. explained_variance
      done;
      make ~points:inputs.Inputs.points ~variances ~model

    let get_common ?predictive ~variances ~sigma2 =
      match predictive with
      | None | Some true ->
          let predictive_variances = Vec.make (Vec.dim variances) sigma2 in
          axpy ~x:variances predictive_variances;
          predictive_variances
      | Some false -> variances

    let get ?predictive { variances = variances; sigma2 = sigma2 } =
      get_common ?predictive ~variances ~sigma2

    module Inducing = struct
      type t = {
        points : Spec.Inducing.t;
        variances : vec;
        sigma2 : float;
      }

      let make ~points ~variances ~model =
        let sigma2 = Common_model.get_sigma2 model in
        { points = points; variances = variances; sigma2 = sigma2 }

      let calc model =
        let b_2_km = calc_b_2_k model ~k:(Common_model.get_km model) in
        let m = Mat.dim2 b_2_km in
        let variances = Vec.create m in
        for i = 1 to m do
          (* TODO: optimize ssqr and col *)
          variances.{i} <- Vec.ssqr (Mat.col b_2_km i)
        done;
        make ~points:(Common_model.get_inducing_points model) ~variances ~model

      let get ?predictive { variances = variances; sigma2 = sigma2 } =
        get_common ?predictive ~variances ~sigma2
    end
  end

  module Common_covariances = struct
    type t = { points : Spec.Inputs.t; covariances : mat; sigma2 : float }

    let make ~points ~covariances ~model =
      let sigma2 = Common_model.get_sigma2 model in
      { points = points; covariances = covariances; sigma2 = sigma2 }

    let make_b_only ~points ~b_2_k ~model =
      make ~points ~covariances:(syrk ~trans:`T b_2_k) ~model

    let get_common ?predictive ~covariances ~sigma2 =
      match predictive with
      | None | Some true ->
          (* TODO: copy upper triangle only *)
          let res = Mat.copy covariances in
          for i = 1 to Mat.dim1 res do res.{i, i} <- res.{i, i} +. sigma2 done;
          res
      | Some false -> covariances

    let get ?predictive { covariances = covariances; sigma2 = sigma2 } =
      get_common ?predictive ~covariances ~sigma2

    let variances { points = points; covariances = covs; sigma2 = sigma2 } =
      { Variances.points = points; variances = Mat.diag covs; sigma2 = sigma2 }

    module Inducing = struct
      type t = {
        points : Spec.Inducing.t;
        covariances : mat;
        sigma2 : float;
      }

      let calc model =
        let points = Common_model.get_inducing_points model in
        let b_2_k = calc_b_2_k model ~k:(Common_model.get_km model) in
        let covariances = syrk ~trans:`T b_2_k in
        let sigma2 = Common_model.get_sigma2 model in
        { points = points; covariances = covariances; sigma2 = sigma2 }

      let get ?predictive { covariances = covariances; sigma2 = sigma2 } =
        get_common ?predictive ~covariances ~sigma2

      let variances { points = points; covariances = covs; sigma2 = sigma2 } =
        {
          Variances.Inducing.
          points = points;
          variances = Mat.diag covs;
          sigma2 = sigma2
        }
    end
  end

  module FITC_covariances = struct
    include Common_covariances

    let calc_common ~kn_diag ~kmn ~km_2_kmn ~points ~model =
      let kernel = Common_model.get_kernel model in
      let covariances = Spec.Inputs.upper_no_diag kernel points in
      for i = 1 to Vec.dim kn_diag do
        covariances.{i, i} <- kn_diag.{i}
      done;
      ignore (syrk ~trans:`T ~alpha:(-1.) km_2_kmn ~beta:1. ~c:covariances);
      let b_2_kmn = calc_b_2_k model ~k:kmn in
      ignore (syrk ~trans:`T ~alpha:1. b_2_kmn ~beta:1. ~c:covariances);
      make ~points ~covariances ~model

    let calc_model_inputs model =
      let kn_diag = model.Common_model.kn_diag in
      let kmn = model.Common_model.inputs.Inputs.kmn in
      let km_2_kmn = model.Common_model.km_2_kmn in
      let points = Common_model.get_input_points model in
      calc_common ~kn_diag ~kmn ~km_2_kmn ~points ~model

    let calc_induced model inputs =
      if Common_model.get_inducing model <> inputs.Inputs.inducing then
        failwith (
          "Make_common.FITC_covariances.calc_induced: \
          model and inputs disagree about inducing points");
      let kmn = inputs.Inputs.kmn in
      let km_2_kmn, kn_diag = Inputs.nystrom_2_marginals inputs in
      let points = inputs.Inputs.points in
      calc_common ~kn_diag ~kmn ~km_2_kmn ~points ~model
  end

  module FIC_covariances = struct
    include Common_covariances

    let calc_model_inputs model =
      let points = Common_model.get_input_points model in
      let lam_diag = model.Common_model.lam_diag in
      let kmn = model.Common_model.inputs.Inputs.kmn in
      let b_2_kmn = calc_b_2_k model ~k:kmn in
      let covariances = syrk ~trans:`T ~alpha:1. b_2_kmn in
      for i = 1 to Vec.dim lam_diag do
        covariances.{i, i} <- lam_diag.{i} +. covariances.{i, i}
      done;
      make ~points ~covariances ~model

    let calc_induced model inputs =
      if Common_model.get_inducing model <> inputs.Inputs.inducing then
        failwith (
          "Make_common.FIC_covariances.calc_induced: \
          model and inputs disagree about inducing points");
      let kmt = inputs.Inputs.kmn in
      let points = inputs.Inputs.points in
      make_b_only ~points ~b_2_k:(calc_b_2_k model ~k:kmt) ~model
  end

  module Common_sampler = struct
    type t = { mean : float; stddev : float }

    let calc ~loc ?predictive mean variance =
      if mean.Mean.point <> variance.Variance.point then
        failwith (
          loc ^ ".Sampler: mean and variance disagree about input point");
      let used_variance =
        match predictive with
        | None | Some true ->
            variance.Variance.variance +. variance.Variance.sigma2
        | Some false -> variance.Variance.variance
      in
      { mean = mean.Mean.value; stddev = sqrt used_variance }

    let sample ?(rng = default_rng) sampler =
      let noise = Gsl_randist.gaussian rng ~sigma:sampler.stddev in
      sampler.mean +. noise

    let samples ?(rng = default_rng) sampler ~n =
      Vec.init n (fun _ -> sample ~rng sampler)
  end

  module Common_cov_sampler = struct
    type t = { means : vec; cov_chol : mat }

    let calc ~loc ?predictive means covariances =
      let module Covariances = Common_covariances in
      if means.Means.points <> covariances.Covariances.points then
        failwith (
          loc ^
          ".Cov_sampler: means and covariances disagree about input points");
      (* TODO: copy upper triangle only *)
      let cov_chol = Mat.copy covariances.Covariances.covariances in
      begin
        match predictive with
        | None | Some true ->
            let sigma2 = covariances.Covariances.sigma2 in
            for i = 1 to Mat.dim1 cov_chol do
              cov_chol.{i, i} <- cov_chol.{i, i} +. sigma2
            done
        | Some false -> ()
      end;
      potrf ~jitter cov_chol;
      { means = means.Means.values; cov_chol = cov_chol }

    let sample ?(rng = default_rng) samplers =
      let n = Vec.dim samplers.means in
      let sample = Vec.init n (fun _ -> Gsl_randist.gaussian rng ~sigma:1.) in
      trmv ~trans:`T samplers.cov_chol sample;
      axpy ~x:samplers.means sample;
      sample

    let samples ?(rng = default_rng) { means = means; cov_chol = cov_chol } ~n =
      let n_means = Vec.dim means in
      let samples =
        Mat.init_cols n_means n (fun _ _ -> Gsl_randist.gaussian rng ~sigma:1.)
      in
      trmm ~trans:`T cov_chol ~b:samples;
      for col = 1 to n do
        for row = 1 to n_means do
          let mean = means.{row} in
          samples.{row, col} <- samples.{row, col} +. mean
        done
      done;
      samples
  end
end

module Make_traditional (Spec : Specs.Eval) = struct
  include Make_common (Spec)
  module Model = Common_model
end

module Make_variational (Spec : Specs.Eval) = struct
  include Make_common (Spec)
  module Model = Variational_model
end

module FIC_Loc = struct let loc = "FIC" end
module Variational_FITC_Loc = struct let loc = "Variational_FITC" end
module Variational_FIC_Loc = struct let loc = "Variational_FIC" end

let fitc_loc = "FITC"
let fic_loc = "FIC"
let variational_fitc_loc = "Variational_FITC"
let variational_fic_loc = "Variational_FIC"

module Make_FITC (Spec : Specs.Eval) = struct
  include Make_traditional (Spec)
  module Covariances = FITC_covariances

  module Sampler = struct
    include Common_sampler
    let calc = calc ~loc:fitc_loc
  end

  module Cov_sampler = struct
    include Common_cov_sampler
    let calc = calc ~loc:fitc_loc
  end
end

module Make_FIC (Spec : Specs.Eval) = struct
  include Make_traditional (Spec)
  module Covariances = FIC_covariances

  module Sampler = struct
    include Common_sampler
    let calc = calc ~loc:fic_loc
  end

  module Cov_sampler = struct
    include Common_cov_sampler
    let calc = calc ~loc:fic_loc
  end
end

module Make_variational_FITC (Spec : Specs.Eval) = struct
  include Make_variational (Spec)
  module Covariances = FITC_covariances

  module Sampler = struct
    include Common_sampler
    let calc = calc ~loc:variational_fitc_loc
  end

  module Cov_sampler = struct
    include Common_cov_sampler
    let calc = calc ~loc:variational_fitc_loc
  end
end

module Make_variational_FIC (Spec : Specs.Eval) = struct
  include Make_variational (Spec)
  module Covariances = FIC_covariances

  module Sampler = struct
    include Common_sampler
    let calc = calc ~loc:variational_fic_loc
  end

  module Cov_sampler = struct
    include Common_cov_sampler
    let calc = calc ~loc:variational_fic_loc
  end
end

module Make (Spec : Specs.Eval) = struct
  module type Sig = Sigs.Eval with module Spec = Spec

  module Common = Make_common (Spec)

  module FITC = struct
    include Common
    module Model = Common_model
    module Covariances = FITC_covariances

    module Sampler = struct
      include Common_sampler
      let calc = calc ~loc:fitc_loc
    end

    module Cov_sampler = struct
      include Common_cov_sampler
      let calc = calc ~loc:fitc_loc
    end
  end

  module FIC = struct
    include Common
    module Model = Common_model
    module Covariances = FIC_covariances

    module Sampler = struct
      include Common_sampler
      let calc = calc ~loc:fic_loc
    end

    module Cov_sampler = struct
      include Common_cov_sampler
      let calc = calc ~loc:fic_loc
    end
  end

  module Variational_FITC = struct
    include Common
    module Model = Variational_model
    module Covariances = FITC_covariances

    module Sampler = struct
      include Common_sampler
      let calc = calc ~loc:variational_fitc_loc
    end

    module Cov_sampler = struct
      include Common_cov_sampler
      let calc = calc ~loc:variational_fitc_loc
    end
  end

  module Variational_FIC = struct
    include Common
    module Model = Variational_model
    module Covariances = FIC_covariances

    module Sampler = struct
      include Common_sampler
      let calc = calc ~loc:variational_fic_loc
    end

    module Cov_sampler = struct
      include Common_cov_sampler
      let calc = calc ~loc:variational_fic_loc
    end
  end
end


(* Derivable *)

module Make_common_deriv
  (Eval_spec : Specs.Eval)
  (Deriv_spec :
    Specs.Deriv
      with type Kernel.t = Eval_spec.Kernel.t
      with type Inducing.t = Eval_spec.Inducing.t
      with type Inputs.t = Eval_spec.Inputs.t) =
struct
  module Eval_common = Make_common (Eval_spec)

  open Eval_common

  module Deriv_common = struct
    module Spec = Deriv_spec

    open Spec

    module Inducing = struct
      type t = {
        eval_inducing : Eval_common.Inducing.t;
        shared : Spec.Inducing.shared;
      }

      let calc kernel points =
        let km, shared = Spec.Inducing.calc_shared kernel points in
        let eval_inducing =
          Eval_common.Inducing.calc_internal kernel points km
        in
        {
          eval_inducing = eval_inducing;
          shared = shared;
        }

      let calc_eval inducing = inducing.eval_inducing
    end

    module Inputs = struct
      type t = {
        inducing : Eval_common.Inducing.t;
        eval_inputs : Eval_common.Inputs.t;
        shared_cross : Spec.Inputs.cross;
      }

      let calc inducing points =
        let kernel = inducing.Eval_common.Inducing.kernel in
        let kmn, shared_cross =
          Spec.Inputs.calc_shared_cross kernel
            ~inducing:inducing.Eval_common.Inducing.points ~inputs:points
        in
        let eval_inputs =
          Eval_common.Inputs.calc_internal inducing points kmn
        in
        {
          inducing = inducing;
          eval_inputs = eval_inputs;
          shared_cross = shared_cross;
        }

      let get_kernel inputs = Eval_common.Inducing.get_kernel inputs.inducing
    end

    module Common_model = struct
      type t = {
        inputs : Inputs.t;
        eval_model : Eval_common.Common_model.t;
        shared_diag : Spec.Inputs.diag;
        calc_evidence : Hyper.t -> float;
        calc_evidence_sigma2 : unit -> float;
      }

      module Eval_inducing = Eval_common.Inducing
      module Eval_inputs = Eval_common.Inputs

      let calc inputs =
        let kernel = Inputs.get_kernel inputs in
        let eval_inputs = inputs.Inputs.eval_inputs in
        let kn_diag, shared_diag =
          Spec.Inputs.calc_shared_diag kernel
            eval_inputs.Eval_common.Inputs.points
        in
        let km_2_kmn =
          calc_basis_2_k
            eval_inputs.Eval_inputs.inducing.Eval_inducing.km_chol
            ~k:eval_inputs.Eval_inputs.kmn
        in
        let eval_model =
          Eval_common.Common_model.calc_internal
            inputs.Inputs.eval_inputs km_2_kmn kn_diag
        in
        let calc_evidence _hyper =
          (assert false (* XXX *))
        in
        let calc_evidence_sigma2 () =
          (assert false (* XXX *))
        in
        {
          inputs = inputs;
          eval_model = eval_model;
          shared_diag = shared_diag;
          calc_evidence = calc_evidence;
          calc_evidence_sigma2 = calc_evidence_sigma2;
        }

      let calc_evidence model hyper = model.calc_evidence hyper
      let calc_evidence_sigma2 model = model.calc_evidence_sigma2 ()
    end

    module Variational_model = struct
      include Common_model

      let calc inputs =
        let model = calc inputs in
        let calc_evidence hyper =
          model.Common_model.calc_evidence hyper
          +.
          (assert false (* XXX *))
        in
        let calc_evidence_sigma2 () =
          model.Common_model.calc_evidence_sigma2 ()
          +.
          (assert false (* XXX *))
        in
        {
          model with
          calc_evidence = calc_evidence;
          calc_evidence_sigma2 = calc_evidence_sigma2;
        }
    end
  end
end
