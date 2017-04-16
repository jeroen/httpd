#' Worker server
#'
#' Example which handles POST / PUT requests in worker procs.
#'
#' @export
#' @param app callback function
#' @param port which port to run the httpd
#' @param size number of worker processes
#' @param preload character vector of packages to preload in the workers
#' @importFrom utils getFromNamespace
#' @importFrom parallel makeCluster stopCluster
#' @examples \dontrun{
#' httpd(function(env){
#' library(lme4)
#' fm1 <- lmer(Reaction ~ Days + (Days | Subject), sleepstudy)
#' str <- paste(capture.output(print(fm1)), collapse = "\n")
#' list(
#'   status = 200,
#'   body = paste("pid:", Sys.getpid(), "\n\n", str),
#'   headers = c("Content-Type" = "text/plain")
#' )
#' }, preload = "lme4")
#' }
httpd <- function(app, port = 9999, size = 4, preload = NULL) {
  # imports
  sendCall <- getFromNamespace('sendCall', 'parallel')
  recvResult <- getFromNamespace('recvResult', 'parallel')

  # globals
  workers <- list()

  # add new workers if needed
  add_workers <- function(n = 1){
    if(length(workers) < size){
      cl <- makeCluster(n)
      lapply(cl, sendCall, fun = function(){
        lapply(preload, getNamespace)
      }, args = list())
      workers <<- c(workers, cl)
    }
  }

  # get a worker
  get_worker <- function(){
    if(!length(workers))
      add_workers(1)
    node <- workers[[1]]
    workers <<- workers[-1]
    res <- recvResult(node)
    if(inherits(res, "try-error"))
      stop("Cluster failed init: ", res)
    structure(list(node), class = c("SOCKcluster", "cluster"))
  }

  # main interface
  run_worker <- function(fun, ...){
    cl <- get_worker()
    on.exit(stopCluster(cl))
    node <- cl[[1]]
    sendCall(node, fun, list(...))
    res <- recvResult(node)
    if(inherits(res, "try-error"))
      stop("Eval failed: ", res)
    res
  }

  # Init
  add_workers(size)
  server_id <- httpuv::startServer("0.0.0.0", port, app = list(call = function(env){
    if(tolower(env[["REQUEST_METHOD"]]) %in% c("post", "put")){
      run_worker(app, env)
    } else {
      app(env)
    }
  }))

  # Cleanup server when terminated
  on.exit(httpuv::stopServer(server_id), add = TRUE)
  on.exit(stopCluster(structure(workers, class = c("SOCKcluster", "cluster"))), add = TRUE)

  # Main loop
  repeat {
    httpuv::service()
    add_workers()
    Sys.sleep(0.001)
  }
}
