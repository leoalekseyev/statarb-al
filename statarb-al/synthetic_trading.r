## simulate prices + trading
## to use in a batch run:
## for(i in seq(1:200)){ source("synthetic_trading.r"); cat(i,":",last(sim.trades$equity),"\n")  }
setwd("/home/leo/projects/finance/research/statarb-al/")
require("fBasics")
require("timeSeries")
require("fGarch")
source("f_trading_sim.r") ## for the trading simulation
source("functions.r") ## for get.signals.mtx() and get.signals.actions()

## GARCH simulation functions:
fGarch.obj.to.model <- function(fgarch.obj){
  params <- fgarch.obj@fit$params$params
  ar.idxs <- grep("^ar",names(params))
  ma.idxs <- grep("^ma",names(params))
  alpha.idxs <- grep("^alpha",names(params))
  beta.idxs <- grep("^beta",names(params))
  model <- list()
  if(!zero.length(ar.idxs)) model$ar <- params[ar.idxs]
  if(!zero.length(ma.idxs)) model$ma <- params[ma.idxs]
  model$omega <- params["omega"]
  model$alpha <- params[alpha.idxs]
  model$beta <- params[beta.idxs]
  model$mu <- params["mu"]
  if(!is.na(params["skew"])) model$skew=params["skew"]
  if(!is.na(params["shape"])) model$shape=params["shape"]
  return(model)
}

build.sim.spec <- function(fgarch.fit){
  garchSpec(model=fGarch.obj.to.model(fgarch.fit)
            , cond.dist=fgarch.fit@fit$params$cond.dist
            , presample=cbind(residuals(fgarch.fit,standardize=T),fgarch.fit@h.t,fgarch.fit@data)) }
  
plot.sim.results <- function(ser.list,xlim.d=c(-0.2,0.2),ylim.d=NULL,xlim.q=NULL,ylim.q=c(-0.3,0.3)){
  stopifnot(class(ser.list)=="list")
  par.save()
  par(mfcol=c(length(ser.list),2))
  lapply(ser.list,function(x)  my.densityPlot(x,xlim=xlim.d,ylim=ylim.d))
  lapply(ser.list,function(x){ qqnorm(x,xlim=xlim.q,ylim=ylim.q); qqline(x) })
  par.restore()
}

## AR fitting/simulation functions:
fit.ar1.series <- function(x) ar(x, aic=F, order.max=1, method="yw")
ar.params.from.fit <- function(x){ ## x is ar fit
  stopifnot(class(x)=="ar" || class(x)=="Arima")
  if(class(x)=="ar"){
    return(lapply(list(m=x$x.mean
                       , a=x$x.mean*(1-x$ar)
                       , b=x$ar
                       , varz=x$var.pred),unname))
  }else{
    return(lapply(list(m=x$coef["intercept"]
                       , a=x$coef["intercept"]*(1-x$coef["ar1"])
                       , b=x$coef["ar1"]
                       , varz=x$sigma2),unname))
  } }
sim.ar1.series <- function(ar,mean,innov.var,n=1000){ ## mean here is series mean=a/(1-b)
  arima.sim(list(order=c(1,0,0), ar=ar), n=n, rand.gen = function(n,...) rnorm(n,mean=mean*(1-ar),sd=sqrt(innov.var)))
}
## this assumes ret[i+1]=(S[i+1]-S[i])/S[i]
ret.to.prices <- function(ret,p0){
  x <- rep(0,length(ret))
  x[1] <- p0
  for(i in seq(along=ret)[c(-1)])
    x[i] <- x[i-1]*(ret[i]+1)
  x
}

get.ticker.classifier.df <- function(t,c){ data.frame(TIC=t,SEC_ETF=c,row.names=t,stringsAsFactors=FALSE) }
get.sim.signals <- function(stk.series,etf.series,tkr.classifier,num.days,win=60){
  stock.etf.signals(data.frame(stk.series), data.frame(etf.series), tkr.classifier, num.days=num.days,compact.output=TRUE,win=win) }


load("xlf.prices.RObj")
xlf.pr <- rev(as.numeric(xlf.prices$XLF))[1:2000]
xlf.lret <- removeNA(diff(log(xlf.pr)))
gf1=garchFit(formula=~arma(0,0)+garch(1,1),xlf.lret,trace=F)

N <- 1000
etf.sim <- garchSim(spec=build.sim.spec(gf1),n=N)  ##using straight up GARCH(1,1) w/ normal innov.

dt <- 1/252
const.beta <- 1.25
const.a <- 0.0009
const.b <- 0.82
const.varz <- 8e-5
const.k <- -log(const.b)/dt
const.m <- const.a/(1-const.b)
const.seq <- sqrt(const.varz/(1-const.b^2))
const.params <- c("m"=const.m,"a"=const.a,"b"=const.b,"varz"=const.varz)
## simulate stock returns
stk.ret.beta <- etf.sim*const.beta
stk.ret.ar1 <- sim.ar1.series(const.b,const.a/(1-const.b),const.varz,length(etf.sim))
stk.ret.ar1.diff <- c(stk.ret.ar1[1],diff(stk.ret.ar1))
stk.ret.tot <- stk.ret.beta+stk.ret.ar1.diff
stk.s.score <- (stk.ret.ar1-const.m)/const.seq

names(stk.ret.tot) <- "STK"
names(etf.sim) <- "ETF"

s.price.init <- 25.385
e.price.init <- 22.825
## generate the price series
stk.prices.beta <- ret.to.prices(stk.ret.beta,s.price.init)
stk.prices <- ret.to.prices(stk.ret.tot,s.price.init)
etf.prices <- ret.to.prices(etf.sim,e.price.init)
sim.prices.df <- data.frame(ETF=etf.prices,STK=stk.prices,row.names=row.names(etf.sim))


tc.df <- get.ticker.classifier.df(c("STK"),c("ETF"))
num.days <- N
thresholds=c(sbo=1.25,sso=1.25,sbc=0.75,ssc=0.5,kmin=8.4)


est.win <- 60
sim.sig.1 <- get.signals(stk.ret.tot,etf.sim,tc.df,num.days=N-est.win+1,win=est.win)
sim.sig.mtx.1 <- get.signals.mtx(sim.sig.1)
sim.sig.actions.1 <- get.signals.actions(sim.sig.mtx.1)

sim.trades <- run.trading.simulation(  sim.sig.1, sim.prices.df
                                     , c("STK"), c("STK","ETF"), debug=FALSE, silent=TRUE, stop.on.wrn=TRUE
                                     , tc.df)

## unlist(ar.params.from.fit(arima(cumsum(stk.ret.tot-const.beta*etf.sim),order=c(1,0,0))))
## unlist(ar.params.from.fit(arima(cumsum(stk.ret.tot-1.265*etf.sim),order=c(1,0,0))))
