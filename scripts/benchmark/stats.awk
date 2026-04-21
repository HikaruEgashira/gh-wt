# compute count, mean, stddev, min, median, max, 95% CI half-width (t_{0.975, n-1} with n=5 → 2.776)
function sqrt_safe(x) { return x>0 ? sqrt(x) : 0 }
BEGIN { FS="\t" }
NR>1 && $3 != "" {
    n++; v[n]=$3+0; s+=$3; s2+=$3*$3
}
END {
    if (!n) { print "no data"; exit }
    mean = s/n
    var  = (n>1) ? (s2 - n*mean*mean)/(n-1) : 0
    sd   = sqrt_safe(var)
    # median
    for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (v[i]>v[j]) { t=v[i]; v[i]=v[j]; v[j]=t }
    if (n%2) med = v[int(n/2)+1]; else med = (v[n/2]+v[n/2+1])/2
    t975 = (n==5) ? 2.776 : 2.262  # n=10 fallback
    ci95 = t975 * sd / sqrt(n)
    printf "n=%d mean=%.3f sd=%.3f median=%.3f min=%.3f max=%.3f CI95=%.3f\n", n, mean, sd, med, v[1], v[n], ci95
}
