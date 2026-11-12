#include <metal_stdlib>
using namespace metal;
// Original YouRec kernels. All creative operations receive display-referred,
// linear BT.709 rgba16Float. Spatial parameters scale from a 1080px short edge.
struct EffectUniforms {
    uint kind, frame, flags, count;
    float time, intensity, duration, fps;
    float4 p[40];
    float4 palette[16];
    float4 thresholds[4];
};
constant uint EFFECT_KIND [[function_constant(0)]];
constant float3 LUMA = float3(0.2126,0.7152,0.0722);
constant sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
float luma(float3 c) { return dot(c,LUMA); }
float3 srgb(float3 c) { return select(c*12.92, 1.055*pow(max(c,0.0),float3(1.0/2.4))-0.055, c>0.0031308); }
float3 lin(float3 c) { return select(c/12.92,pow((c+0.055)/1.055,float3(2.4)),c>0.04045); }
float3 lab(float3 c) {
    float3 v = pow(max(float3(dot(c,float3(.4122214708,.5363325363,.0514459929)),dot(c,float3(.2119034982,.6806995451,.1073969566)),dot(c,float3(.0883024619,.2817188376,.6299787005))),0.0),float3(1.0/3.0));
    return float3(dot(v,float3(.2104542553,.793617785,-.0040720468)),dot(v,float3(1.9779984951,-2.428592205,.4505937099)),dot(v,float3(.0259040371,.7827717662,-.808675766)));
}
float3 unlab(float3 c) {
    float3 v=float3(c.x+.3963377774*c.y+.2158037573*c.z,c.x-.1055613458*c.y-.0638541728*c.z,c.x-.0894841775*c.y-1.291485548*c.z);v=v*v*v;
    return float3(dot(v,float3(4.0767416621,-3.3077115913,.2309699292)),dot(v,float3(-1.2684380046,2.6097574011,-.3413193965)),dot(v,float3(-.0041960863,-.7034186147,1.707614701)));
}
float3 hsv(float3 c) {
    float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b)),d=hi-lo,h=0;
    if(d>1e-6) { if(hi==c.r) h=fmod((c.g-c.b)/d+6.0,6.0); else if(hi==c.g) h=(c.b-c.r)/d+2; else h=(c.r-c.g)/d+4; }
    return float3(h/6,hi>1e-6?d/hi:0,hi);
}
float hueDistance(float a,float b) { float d=abs(a-b);return min(d,1-d); }
uint hash32(uint n) { n^=n>>16;n*=0x7feb352du;n^=n>>15;n*=0x846ca68bu;n^=n>>16;return n; }
float random01(uint3 v) { return float(hash32(v.x ^ hash32(v.y+0x9e3779b9u) ^ hash32(v.z+0x85ebca6bu))>>8)/16777216.0; }
float noise(float2 pixel,uint frame,uint seed) {
    int2 cell=int2(floor(pixel));float2 f=fract(pixel);f=f*f*(3-2*f);
    float a=random01(uint3(uint2(cell),frame+seed)),b=random01(uint3(uint2(cell+int2(1,0)),frame+seed));
    float c=random01(uint3(uint2(cell+int2(0,1)),frame+seed)),d=random01(uint3(uint2(cell+int2(1,1)),frame+seed));
    return mix(mix(a,b,f.x),mix(c,d,f.x),f.y)*2-1;
}
// The random lattice is shared within a frame. Interpolating the already
// correlated channels is equivalent to interpolating four separate hashes.
// A single sampling map drives both the picture and its auxiliary masks.
// Coordinates are normalised and top-down; size is the picture size even
// when the map being warped is a reduced-resolution segmentation texture.
// Validity travels premultiplied through resampling; divide it back out
// before interpreting disparity, so invalid neighbours cannot bias it to far.
float2 depthAt(texture2d<half,access::sample> image,float2 uv) {
    float2 value=float2(image.sample(linearSampler,uv).rg);
    return float2(value.x/max(value.y,.001),value.y);
}
float2 effectPoint(float2 uv,float2 size,constant EffectUniforms &u) {
    float pixelScale=min(size.x,size.y)/1080.0;
    switch(u.kind) {
    case 22: {
        // Polar distances are in pixels, so a 120-degree wedge stays 120
        // degrees in either orientation. The first clockwise sector is kept.
        uint count = uint(clamp(round(u.p[0].x), 2.0f, 9.0f));
        float2 center = float2(u.p[1].x, u.p[2].x);
        float2 d = (uv - center) * size;
        float2 point = uv;
        if (dot(d, d) >= 1e-8f) {
            float axis = u.p[3].x * (M_PI_F / 180.0f) - M_PI_F / 2;
            float turn = 2 * M_PI_F;
            float span = turn / float(count);
            float angle = fract((atan2(d.y, d.x) - axis) / turn) * turn;
            uint sector = min(uint(angle / span), count - 1);
            if (sector != 0) {
                float local = angle - float(sector) * span;
                // Odd rings repeat the entire wedge by rotation. Even rings alternate reflections.
                if ((count & 1u) == 0 && (sector & 1u) != 0) local = span - local;
                float mapped = axis + local;
                point = center + length(d) * float2(cos(mapped), sin(mapped)) / size;
            }
        }
        // Inverse-map the source rotation in picture pixels. The texel under
        // the junction stays pinned, even on a panned, non-square source.
        if (u.p[6].x != 0) {
            float a = -u.p[6].x * (M_PI_F / 180.0f);
            float2 offset = (point - center) * size;
            float c = cos(a), s = sin(a);
            point = center + float2(c * offset.x - s * offset.y, s * offset.x + c * offset.y) / size;
        }
        point -= float2(u.p[4].x, u.p[5].x);
        if (all(point >= 0.0f) && all(point <= 1.0f)) return point;
        return 1.0f - abs(2.0f * fract(point * 0.5f) - 1.0f);
    }
    case 9: {
        float t=u.time,speed=max(.001,u.p[1].x),z=1;
        float release=(u.flags&4)?u.p[39].x:speed+.08+u.p[2].x;
        if(t<speed)z=mix(1.0,u.p[0].x,pow(clamp(t/speed,0.0,1.0),5));
        else if(t<speed+.08)z=u.p[0].x*(1+.03*sin((t-speed)/.08*M_PI_F));
        else if((u.p[3].x>.5||(u.flags&4))&&t>release){float f=clamp((t-release)/speed,0.0,1.0);z=mix(u.p[0].x,1.0,f*f*(3-2*f));}
        else z=u.p[0].x;
        float2 target=float2(u.p[5].x,u.p[6].x);return (uv-target)/z+target;
    }
    case 12: return (uv-.5)/(1+u.p[1].x*clamp(u.time/max(.001,u.p[0].x),0.0,1.0))+.5;
    case 14: {
        uint frame=uint(floor(u.time*u.p[0].x));float2 move=float2(noise(float2(float(frame)*.18,3),0,7)*2,noise(float2(float(frame)*.18,8),0,11)*3)*u.p[3].x*pixelScale;
        return (uv-.5)/1.01+.5+move/size;
    }
    case 16: {
        float2 move=float2(noise(float2(float(u.frame)*.13,2),0,7),noise(float2(float(u.frame)*.13,9),0,3))*u.p[3].x*pixelScale*2;
        return (uv-.5)/1.006+.5+move/size;
    }
    case 17: {
        float2 move=float2(noise(float2(float(u.frame)*.16,2),0,5)*2,noise(float2(float(u.frame)*.16,9),0,17)*3)*u.p[2].x*pixelScale;
        return (uv-.5)/1.012+.5+move/size;
    }
    default:return uv;
    }
}
kernel void ve_geometryMap(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],texture2d<half,access::sample> focus [[texture(2)]],constant EffectUniforms &u [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height()),point=effectPoint(uv,u.p[38].xy,u);
    // Camera sampling clamps at the frame edge; maps follow that same rule.
    half4 mapped=input.sample(linearSampler,point);
    if(u.kind==8&&u.p[38].z>.5) {
        float2 d=depthAt(input,uv),f=float2(focus.read(uint2(0)).rg);
        float a=d.y>.9&&f.y>.5?smoothstep(f.x-.12,f.x-.025,d.x):1;
        float t=clamp(u.time/max(.001,u.p[2].x),0.0,1.0);if(u.p[3].x<.5)t=t<.5?4*t*t*t:1-pow(-2*t+2,3)/2;
        float scale=u.p[0].x<.5?1+u.p[1].x*t:1+u.p[1].x*(1-t);float2 target=float2(u.p[4].x,u.p[5].x);
        float2 point=(uv-target)/scale+target,sd=depthAt(input,point);
        half4 scaled=input.sample(linearSampler,point);
        float sa=sd.y>.9&&f.y>.5?smoothstep(f.x-.12,f.x-.025,sd.x):1;
        // The picture fills disocclusions with estimated background. Avoid
        // copying the foreground's disparity into that filled background ring.
        scaled=mix(scaled,mapped,half(sa));mapped=mix(scaled,mapped,half(a));
    }
    if((u.kind==18||u.kind==19)&&u.p[38].z>.5) {
        half alpha=focus.sample(linearSampler,uv).r;
        // Replacement media is a flat backdrop behind all original depths.
        // The final key matte, including hair, defines which depths survive.
        mapped=mix(half4(-.3,1,0,1),mapped,alpha);
    }
    output.write(mix(input.sample(linearSampler,uv),mapped,half(u.intensity)),q);
}
float3 grain(float3 c,float2 pixel,uint frame,float strength,float size,bool mono,texture2d<half,access::sample> lattice) {
    float y=clamp(luma(c),0.0,1.0),a=strength*.12*pow(max(0.0,4*y*(1-y)),.7);
    float2 point=pixel/size,cell=floor(point),f=fract(point);f=f*f*(3-2*f);
    float4 value=float4(lattice.sample(linearSampler,(cell+.5+f)/float2(lattice.get_width(),lattice.get_height())));
    return clamp(c*exp((mono?float3(value.a):value.rgb)*a*2.0),0.0,1.0);
}
float3 sampleImage(texture2d<half,access::sample> image,float2 uv) {return float3(image.sample(linearSampler,uv).rgb);}
float3 cubicSample(texture2d<half,access::sample> image,float2 uv) {
    float2 size=float2(image.get_width(),image.get_height()),q=uv*size-.5,base=floor(q),f=q-base;
    float3 out=0;float total=0;
    for(int y=-1;y<=2;y++) for(int x=-1;x<=2;x++) {
        float2 d=abs(float2(x,y)-f),w;
        for(uint k=0;k<2;k++) {float v=d[k];w[k]=v<=1?1.5*v*v*v-2.5*v*v+1:v<2?-.5*v*v*v+2.5*v*v-4*v+2:0;}
        float weight=w.x*w.y;out+=sampleImage(image,(base+float2(x,y)+.5)/size)*weight;total+=weight;
    }
    return out/max(total,1e-6);
}
float sCurve(float y,float contrast) { y=clamp(y,0.0,1.0);float a=pow(y,contrast),b=pow(1-y,contrast);return a/max(a+b,1e-6); }
// Controls operate on perceptual tone values; image math and compositing stay
// linear. A 0.5 linear pivot crushed normal skin at the default contrast.
float curve(float y,float contrast) { return lin(float3(clamp((srgb(float3(y)).x-.5)*contrast+.5,0.0,1.0))).x; }
float gate(float2 uv,float radius) {
    float2 d=abs(uv-.5)-float2(.5-radius);
    return 1-smoothstep(radius-.004,radius+.004,length(max(d,0.0))+min(max(d.x,d.y),0.0));
}
float bayer(uint2 q,uint size) {
    uint value=0;
    for(uint bit=0; (1u<<bit)<size;bit++) {uint x=(q.x>>bit)&1u,y=(q.y>>bit)&1u;value=(value<<2)|((x^y)*2+y);}
    return (float(value)+.5)/float(size*size);
}
// Disparity is data, never RGB. R is a fixed source-wide normalisation;
// G is validity, so missing depth cannot masquerade as distant background.
struct DepthPlacement {float4 inverseX,inverseY,dimensions,range;};
kernel void ve_depthPlace(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant DepthPlacement &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height());
    float3 canvas=float3(uv.x*p.dimensions.z,(1-uv.y)*p.dimensions.w,1);
    float2 source=float2(dot(p.inverseX.xyz,canvas),dot(p.inverseY.xyz,canvas));
    float2 point=float2(source.x/p.dimensions.x,1-source.y/p.dimensions.y);
    half2 result=0;
    if(all(point>=0)&&all(point<=1)) {
        // Do not linearly interpolate NaNs or missing pixels into valid depth.
        constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
        float value=float(input.sample(nearest,point).r);
        if(isfinite(value))result=half2(clamp((value-p.range.x)/p.range.y,0.0,1.0),1);
    }
    output.write(half4(result,0,1),q);
}
kernel void ve_depthFocus(texture2d<half,access::sample> depth [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant float4 &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x||q.y)return;
    float values[81];uint count=0;
    if(p.x>=0) {output.write(half4(p.x,1,0,1),uint2(0));return;}
    float2 step=1.0/float2(depth.get_width(),depth.get_height());
    for(int y=-4;y<=4;y++)for(int x=-4;x<=4;x++) {
        float2 sample=depthAt(depth,p.yz+float2(x,y)*step);
        if(sample.y>.9&&sample.x>=0) {uint j=count++;while(j>0&&values[j-1]>sample.x){values[j]=values[j-1];j--;}values[j]=sample.x;}
    }
    output.write(count?half4(values[count/2],1,0,1):half4(0),uint2(0));
}
kernel void ve_depthMask(texture2d<half,access::sample> depth [[texture(0)]],texture2d<half,access::sample> focus [[texture(1)]],texture2d<half,access::write> output [[texture(2)]],constant uint &unused [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height()),d=depthAt(depth,uv),f=float2(focus.read(uint2(0)).rg);
    // Invalid pixels remain in the foreground; don't move or blur holes.
    float a=d.y>.9&&f.y>.5?smoothstep(f.x-.12,f.x-.025,d.x):1;
    output.write(half4(a,0,0,1),q);
}
kernel void ve_bokehAmount(texture2d<half,access::sample> depth [[texture(0)]],texture2d<half,access::sample> focus [[texture(1)]],texture2d<half,access::write> output [[texture(2)]],constant uint &unused [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height()),d=depthAt(depth,uv),f=float2(focus.read(uint2(0)).rg);
    float amount=d.y>.9&&f.y>.5?smoothstep(.015,.08,f.x-d.x):0;
    output.write(half4(amount,0,0,1),q);
}
kernel void ve_depthBokeh(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::sample> depth [[texture(1)]],texture2d<half,access::sample> focus [[texture(2)]],texture2d<half,access::write> output [[texture(3)]],constant float &radius [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height()),d=depthAt(depth,uv),f=float2(focus.read(uint2(0)).rg);
    float coc=d.y>.9&&f.y>.5?clamp((f.x-d.x-.015)/.5,0.0,1.0):0;
    float2 step=radius*coc*float2(1.8,1)/float2(input.get_width(),input.get_height());
    float3 color=sampleImage(input,uv);float weight=1;
    if(coc>.01)for(uint i=0;i<64;i++) {
        float angle=float(i)*2.39996323,r=sqrt((float(i)+.5)/64);
        float2 point=uv+float2(cos(angle),sin(angle))*r*step;
        float2 sample=depthAt(depth,point);
        // A disc aperture, not a Gaussian: retain highlight circles, and
        // reject foreground taps so faces do not bleed into the background.
        float w=sample.y>.9&&sample.x<f.x-.02&&sample.x<d.x+.06?1:0;
        color+=sampleImage(input,point)*w;weight+=w;
    }
    output.write(half4(half3(color/weight),1),q);
}
kernel void ve_toneMap(texture2d<half,access::read> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant uint &hdr [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float3 c=float3(input.read(q).rgb);
    if(hdr) {
        // SDR highlight shoulder, identity through 0.75 reference-white luma.
        float y=max(1e-6,luma(c)),mapped=y<=.75?y:.75+.25*(1-exp(-(y-.75)/.25));c*=mapped/y;
        float3 delta=c-mapped;float limit=1;
        for(uint i=0;i<3;i++) {if(delta[i]>0)limit=min(limit,(1-mapped)/delta[i]);else if(delta[i]<0)limit=min(limit,-mapped/delta[i]);}
        c=mapped+delta*max(0.0,limit);
    }
    output.write(half4(half3(clamp(c,0.0,1.0)),1),q);
}
// Primary grading is original code, not a LUT or a camera white-balance setting.
// Input is the pipeline's display-referred linear BT.709 after its HDR tone map.
// Exposure is linear stops; tone controls operate on perceptual luma. Bounded
// polynomial tone adjustments have positive derivatives across their full range.
// All tone changes share one RGB ratio, avoiding per-channel contrast hue shifts.
float3 gradeGamut(float3 c) {
    float y=clamp(luma(c),0.0,1.0),amount=1;float3 delta=c-y;
    for(uint i=0;i<3;i++) {
        if(delta[i]>0)amount=min(amount,(1-y)/delta[i]);
        else if(delta[i]<0)amount=min(amount,-y/delta[i]);
    }
    return y+delta*max(0.0,amount);
}
// C1 rational shoulder fits a known maximum to white, preserving every level
// and a unit slope at the knee. Mirroring it gives a toe for negative Blacks.
float gradeShoulder(float value,float maximum) {
    if(maximum<=1 || value<=.8)return value;
    float a=(maximum-.8)/.2,t=(value-.8)/(maximum-.8);
    return .8+.2*a*t/(1+(a-1)*t);
}
float3 colorCorrection(float3 c,constant EffectUniforms &u) {
    bool neutral=u.p[0].x==0&&u.p[1].x==1&&u.p[2].x==0&&u.p[3].x==0&&u.p[4].x==0&&u.p[5].x==0&&u.p[7].x==0&&u.p[8].x==0&&u.p[9].x==1&&u.p[10].x==0&&u.p[11].x==0;
    if(neutral)return c; // Pivot alone is inert; preserve the exact half-float input.
    float temperature=u.p[7].x,tint=u.p[8].x;
    float3 gains=exp2(float3(.45*temperature+.2*tint,-.2*tint,-.45*temperature+.2*tint));
    c*=gains/dot(gains,LUMA)*exp2(u.p[0].x);
    float before=luma(c),v=srgb(float3(max(before,0.0))).x;
    v=gradeShoulder(v,srgb(float3(exp2(u.p[0].x))).x);
    float contrast=u.p[1].x,pivot=u.p[6].x;
    if(contrast!=1 && v>0 && v<1) {
        float odds=pivot/(1-pivot);
        v=1/(1+pow(odds,contrast-1)*pow((1-v)/v,contrast));
    }
    v+=u.p[2].x*v*(1-v)*(1-v);
    v+=u.p[3].x*v*v*(1-v);
    v+=.12*u.p[4].x*pow(1-v,4.0)+.12*u.p[5].x*pow(v,4.0);
    v=gradeShoulder(v,1+.12*u.p[5].x);
    v=1-gradeShoulder(1-v,1-.12*u.p[4].x);
    float target=lin(float3(v)).x;
    c=before>1e-7?c*(target/before):float3(target);
    float3 perceptual=lab(max(c,0.0));
    float chroma=length(perceptual.yz);
    // Vibrance mostly affects muted colors; protect common skin hues from boosts.
    float3 h=hsv(srgb(max(c,0.0)));
    float skin=smoothstep(.025,.055,h.x)*(1-smoothstep(.12,.16,h.x))*smoothstep(.08,.2,h.y);
    float vibrance=u.p[10].x*(1-clamp(chroma/.25,0.0,1.0));
    if(vibrance>0)vibrance*=1-.6*skin;
    if(u.p[11].x!=0 && chroma>1e-5) {
        float angle=u.p[11].x*M_PI_F/180,cs=cos(angle),sn=sin(angle);
        perceptual.yz=float2(cs*perceptual.y-sn*perceptual.z,sn*perceptual.y+cs*perceptual.z);
        c=unlab(perceptual);c*=target/max(luma(c),1e-7);
    }
    c=gradeGamut(c);
    float gain=u.p[9].x*(1+vibrance);
    if(gain>1) {
        float3 delta=c-target;float ratio=0;
        for(uint i=0;i<3;i++)ratio=max(ratio,delta[i]>0?delta[i]/max(1-target,1e-7):-delta[i]/max(target,1e-7));
        // A monotone saturation shoulder: full gain on muted colors, smoothly
        // tending to the gamut boundary. Distinct vivid shades stay distinct.
        gain/=sqrt(1+(gain*gain-1)*ratio*ratio);
    }
    c=target+(c-target)*gain;
    // Compress chroma toward neutral at the same luma instead of independently
    // clipping RGB channels (which changes hue, especially on saturated reds).
    return gradeGamut(c);
}
kernel void ve_effect(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::sample> aux [[texture(1)]],texture2d<half,access::sample> mask [[texture(2)]],texture2d<half,access::sample> background [[texture(3)]],texture2d<half,access::write> output [[texture(4)]],texture2d<half,access::sample> extra [[texture(5)]],texture2d<half,access::sample> wrapImage [[texture(6)]],texture2d<half,access::sample> matchSubject [[texture(7)]],texture2d<half,access::sample> matchBackground [[texture(8)]],texture2d<half,access::sample> noiseLattice [[texture(9)]],constant EffectUniforms &u [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 size=float2(output.get_width(),output.get_height()),uv=(float2(q)+.5)/size;
    if (EFFECT_KIND == 22) {
        half4 reflected = input.sample(linearSampler, effectPoint(uv, size, u));
        output.write(u.intensity >= 1 ? reflected : mix(input.sample(linearSampler, uv), reflected, half(u.intensity)), q);
        return;
    }
    if (EFFECT_KIND == 7 && u.count < 2) {
        output.write(input.sample(linearSampler, uv), q);
        return;
    }
    // Quantization reads the smoothed auxiliary image at full intensity.
    // Avoid a discarded full-resolution source read in that common path.
    float3 original=(EFFECT_KIND==7 && u.p[3].x>0 && u.intensity>=1) ? float3(0) : sampleImage(input,uv),c=original,out=c;float y=luma(c),pixelScale=min(size.x,size.y)/1080.0;
    switch(EFFECT_KIND) {
    case 23: {
        float2 reach = 0.12f * min(size.x, size.y) / size;
        float2 red = float2(u.p[0].x, u.p[1].x), green = float2(u.p[2].x, u.p[3].x), blue = float2(u.p[4].x, u.p[5].x);
        out = float3(sampleImage(input, uv - red * reach).r, sampleImage(input, uv - green * reach).g, sampleImage(input, uv - blue * reach).b);
        break;
    }
    case 24: {
        // A photographic negative complements display values, so mid-gray stays mid-gray.
        out = lin(1.0f - srgb(clamp(c, 0.0f, 1.0f)));
        break;
    }
    case 20: out=colorCorrection(c,u);break;
    case 0: { // Silent Tint: contrast and dye in linear light.
        const float3 tints[]={float3(.243137,.435294,.658824),float3(.85098,.643137,.254902),float3(.721569,.262745,.184314),float3(.431373,.560784,.305882),float3(.541176,.415686,.270588)};
        float3 tint=lin(tints[uint(u.p[0].x)]);float l=curve(y,u.p[2].x);
        out=u.p[1].x<.5?l*tint:mix(tint*.15,float3(1),smoothstep(0.0,1.0,l));break;
    }
    case 1: { // Three-Strip; protect skin hue from the red-separation push.
        float3 enc=srgb(c),h=hsv(enc);float skin=smoothstep(.03,.055,h.x)*(1-smoothstep(.115,.15,h.x))*smoothstep(.12,.3,h.y);
        float3 separation=c-(c.yzx+c.zxy)*.5;
        out=c+separation*(u.p[0].x-1)*(1-.65*skin);
        float red=1-smoothstep(15.0/360,25.0/360,hueDistance(h.x,0.0));out.gb-=red*u.p[1].x*.15*(1-skin);
        float l=luma(out),s=l*l*(3-2*l);out+=(s-l)*.14;
        out*=float3(1+u.p[2].x*.06,1,1-u.p[2].x*.06);
        float high=max(out.r,max(out.g,out.b));if(high>.9)out=.9+(out-.9)/(1+max(0.0,high-.9));out=mix(out,c,skin*.35);break;
    }
    case 2: {float3 overlay=y<.5?2*c*y:1-2*(1-c)*(1-y);float3 bleached=mix(float3(y),overlay,.5);bleached=mix(float3(luma(bleached)),bleached,1-.3*u.p[0].x);out=mix(c,bleached,u.p[0].x);break;}
    case 3: {float3 h=hsv(srgb(c));float darkness=u.p[0].x;out=mix(float3(y),c,.4)*exp2(-3*darkness);out*=mix(float3(1),float3(.55,.7,1),u.p[1].x);
        float sky=(1-smoothstep(.25,.38,uv.y))*smoothstep(.5,.85,y)*(1-smoothstep(.08,.18,hueDistance(h.x,.61)));out*=1-.5*sky;
        if(u.p[2].x>.5)out=mix(out,float3(y*exp2(-.7*darkness)),smoothstep(.94,.99,y)*.7);
        out*=1-.15*smoothstep(.2,.75,length(uv-.5));break;}
    case 4: {float w;
        if(u.p[0].x>.5 || (u.flags&8))w=float(mask.sample(linearSampler,uv).r);else {float3 h=hsv(srgb(c)),target=hsv(srgb(u.p[1].xyz));float r=u.p[2].x/360,soft=max(.001,u.p[3].x*.1);w=(1-smoothstep(r,r+soft,hueDistance(h.x,target.x)))*smoothstep(.08,.2,h.y);}
        out=mix(float3(y),c,w);break;}
    case 5: {float l=sCurve(srgb(float3(dot(c,float3(.4,.5,.1)))).x,u.p[0].x);l=lin(float3(l*(1-2*u.p[1].x*(1-l)))).x;out=float3(l);if(u.p[3].x>.5)out*=mix(float3(.94,.97,1),float3(1),l);if(u.p[2].x>.5)out=grain(out,float2(q)/pixelScale,u.frame,.25,1,true,noiseLattice);break;}
    case 6: {float perceptual=srgb(float3(y)).x;float l=sCurve(perceptual,u.p[0].x);l=lin(float3(mix(l,smoothstep(.35,.65,perceptual),.4))).x;float2 d=(uv-.5)*2;if(u.p[2].x>.5)d.x*=size.x/size.y;
        float v=clamp(1-pow(clamp(length(d)/1.25,0.0,1.0),2.5),0.0,1.0);l*=mix(1.0,v,u.p[1].x);out=float3(l);if(u.p[3].x>.5)out*=lin(float3(.82,.84,.52));break;}
    case 7: { // Palette lookup: centroids are Oklab, thresholds linear luma.
        if(u.p[3].x>0)c=sampleImage(aux,uv);y=luma(c);c+=.2*(y*y*(3-2*y)-y);
        if(u.p[5].x>.5&&u.count<=4&&(u.flags&1))c+=(c-sampleImage(background,uv))*.4*float(mask.sample(linearSampler,uv).r);
        float3 v=lab(clamp(c,0.0,1.0));
        if(u.p[4].x>.5) {float spread=0;for(uint i=1;i<u.count;i++)spread+=distance(u.palette[i-1].xyz,u.palette[i].xyz);spread/=max(1u,u.count-1);v.x+=(bayer(q,uint(u.p[4].x)<2?4:8)-.5)*spread;}
        uint best=0;
        if(u.p[1].x>.5 || (u.p[2].x>=1 && u.p[2].x<=3)) {float l=luma(clamp(unlab(v),0.0,1.0));for(uint i=0;i+1<u.count;i++)if(l>=u.thresholds[i/4][i%4])best++;out=u.p[1].x>.5?lin(float3(float(best)/float(max(1u,u.count-1)))):unlab(u.palette[best].xyz);}
        else {float closest=1e10;for(uint i=0;i<u.count;i++){float d=distance_squared(v,u.palette[i].xyz);if(d<closest){closest=d;best=i;}}out=unlab(u.palette[best].xyz);}break;
    }
    case 8: { // Simulated two-layer dolly; live lens control is outside the shader.
        float t=clamp(u.time/max(.001,u.p[2].x),0.0,1.0);if(u.p[3].x<.5)t=t<.5?4*t*t*t:1-pow(-2*t+2,3)/2;
        float scale=u.p[0].x<.5?1+u.p[1].x*t:1+u.p[1].x*(1-t);float2 target=float2(u.p[4].x,u.p[5].x);
        float3 bg=sampleImage(aux,(uv-target)/scale+target);float a=float(mask.sample(linearSampler,uv).r);out=mix(bg,c,a);break;}
    case 9: {float t=u.time,speed=max(.001,u.p[1].x),z=1,velocity=0;float release=(u.flags&4)?u.p[39].x:speed+.08+u.p[2].x;
        if(t<speed){float f=clamp(t/speed,0.0,1.0);z=mix(1.0,u.p[0].x,pow(f,5));velocity=5*pow(f,4)/speed;}
        else if(t<speed+.08){float f=(t-speed)/.08;z=u.p[0].x*(1+.03*sin(f*M_PI_F));velocity=.03*M_PI_F/.08*cos(f*M_PI_F);}
        else if((u.p[3].x>.5||(u.flags&4))&&t>release){float f=clamp((t-release)/speed,0.0,1.0);z=mix(u.p[0].x,1.0,f*f*(3-2*f));velocity=-6*f*(1-f)/speed;}
        else z=u.p[0].x;
        float2 target=float2(u.p[5].x,u.p[6].x),point=effectPoint(uv,size,u);float blur=min(.12,abs(velocity)*.002*u.p[4].x);out=0;
        for(uint i=0;i<8;i++)out+=sampleImage(input,point+(point-target)*blur*(float(i)/7-.5))/8;break;}
    case 11: {const float ratios[]={2.39,2.20,1.85,1.33};float ratio=ratios[uint(u.p[0].x)],aspect=size.x/size.y;
        bool bar=aspect<ratio?abs(uv.y-.5)>.5*aspect/ratio:abs(uv.x-.5)>.5*ratio/aspect;
        const float3 colors[]={float3(.35,.6,1),float3(1,.6,.25),float3(1)};
        if((u.flags&16)&&u.p[4].x>.5) {
            float amount=float(mask.sample(linearSampler,uv).r)*smoothstep(.5,.95,float(matchSubject.sample(linearSampler,uv).g));
            c=mix(c,sampleImage(extra,uv),amount);
        }
        out=c+sampleImage(aux,uv)*colors[uint(u.p[3].x)]*u.p[2].x;
        if(bar)out=u.p[1].x>.5?sampleImage(background,uv)*.6:float3(0);break;}
    case 12: {out=sampleImage(input,effectPoint(uv,size,u));
        if(u.p[2].x>.5){out=mix(float3(luma(out)),out,.95);out*=1-.12*smoothstep(.25,.7,length(uv-.5));out=grain(out,float2(q)/pixelScale,u.frame,.3,1.5,false,noiseLattice);}break;}
    case 13: out=mix(c,sampleImage(aux,uv),u.p[1].x);break;
    case 14: {uint frame=uint(floor(u.time*u.p[0].x));out=sampleImage(input,effectPoint(uv,size,u));out*=1+(random01(uint3(4,7,frame))*2-1)*.08*u.p[2].x;break;}
    case 15: {float3 glow=sampleImage(aux,uv),halo=sampleImage(background,uv);const float3 flashColors[]={float3(1),float3(1,.8,.6),float3(.65,.8,1)};
        out=c+(glow*.65+sampleImage(extra,uv)*.35)*u.p[0].x+halo.r*float3(1,.25,.1)*u.p[1].x+flashColors[uint(u.p[3].x)]*u.p[2].x*.08*(1-y);break;}
    case 16: {float2 point=effectPoint(uv,size,u);out=mix(sampleImage(input,point),sampleImage(aux,point),u.p[2].x);out=out/(1+max(out-.85,0.0)*.15);
        bool mono=u.p[5].x>.5;if(mono)out=float3(luma(out));const float sizes[]={1,1.5,2.2};out=grain(out,float2(q)/pixelScale,u.frame,u.p[0].x,sizes[uint(u.p[1].x)],mono,noiseLattice);if(u.p[4].x>.5)out*=gate(uv,.035);break;}
    case 17: {float2 point=effectPoint(uv,size,u),offset=(uv-.5)*pixelScale/size;
        out=float3(sampleImage(aux,point+offset).r,sampleImage(aux,point).g,sampleImage(aux,point-offset).b);
        out=mix(out,float3(.06)+out*.88,u.p[0].x);out*=float3(1.06,1,.92);out.r+=out.g*.025*u.p[0].x;out=mix(float3(luma(out)),out,.8);out=grain(out,float2(q)/pixelScale,u.frame,u.p[1].x,2.2,false,noiseLattice);
        float cycle=floor(u.time/6),phase=u.time-cycle*6,begin=random01(uint3(uint(cycle),12,3))*4.5,len=.5+random01(uint3(uint(cycle),4,6));
        float pulse=phase>=begin&&phase<begin+len?sin((phase-begin)/len*M_PI_F):0;float edge=random01(uint3(uint(cycle),7,11))>.5?uv.x:1-uv.x;
        out+=float3(1,.22,.035)*exp(-edge*7)*pulse*u.p[4].x;if(u.p[5].x>.5)out*=gate(uv,.055);break;}
    case 18: // Alpha already refined; unmix straight color and multiply ONCE.
    case 19: {float a=float(mask.sample(linearSampler,uv).r);float3 bg=sampleImage(background,uv),screen=EFFECT_KIND==18?((u.flags&2)?sampleImage(aux,uv):u.p[0].xyz):sampleImage(aux,uv);
        // The screen estimate is uncertain near hair. Unbounded division by a
        // tiny alpha amplified that error into an opaque fringe outside people.
        // All effects operate in SDR linear 0...1; bound straight foreground
        // before multiplying by coverage, so nearly clear pixels stay clear.
        float3 straight=clamp((c-(1-a)*screen)/max(a,.0001),0.0,1.0);
        if(EFFECT_KIND==18){bool blue=u.p[1].x>1.5||(u.p[1].x<.5&&screen.b>screen.g);uint channel=blue?2:1;float limit=blue?(straight.r+straight.g)*.525:(straight.r+straight.b)*.525;float before=straight[channel];straight[channel]=min(before,mix(before,limit,u.p[9].x));straight+=(before-straight[channel])*float3(.3,.6,.1)*.5;}
        uint matchIndex=EFFECT_KIND==18?24:15;
        if(u.p[matchIndex].x>.5) {
            float4 subject=float4(matchSubject.sample(linearSampler,float2(.5)));
            float3 target=sampleImage(matchBackground,float2(.5)),mean=subject.rgb/max(.001,subject.a);
            if(subject.a>.001)straight*=mix(float3(1),clamp(target/max(mean,float3(.01)),.5,2.0),u.p[matchIndex+1].x);
        }
        out=straight*a+bg*(1-a);float wrap=EFFECT_KIND==18?u.p[10].x:u.p[2].x;float band=a*(1-a)*4;out+=sampleImage(wrapImage,uv)*band*wrap*.25;
        uint view=uint(EFFECT_KIND==18?u.p[13].x:u.p[4].x);if(view==1)out=float3(a);if(view==2)out=c;break;}
    }
    output.write(half4(half3(u.intensity>=1 ? clamp(out,0.0,1.0) : mix(original,clamp(out,0.0,1.0),u.intensity)),1),q);
}
// Exact Gaussian coefficients are normalized once on CPU. Adjacent positive
// taps share one bilinear sample; this halves reads and removes exp per pixel.
struct GaussianWeights { float4 header; float4 pair[24]; };
kernel void ve_blur(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant GaussianWeights &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 size=float2(output.get_width(),output.get_height()),uv=(float2(q)+.5)/size,direction=p.header.zw/size;
    float4 result=float4(input.sample(linearSampler,uv))*p.header.x;
    for(uint i=0;i<uint(p.header.y);i++) {
        float2 offset=direction*p.pair[i].x;
        result+=(float4(input.sample(linearSampler,uv+offset))+float4(input.sample(linearSampler,uv-offset)))*p.pair[i].y;
    }
    output.write(half4(result),q);
}
kernel void ve_bilateral(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant float4 &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 size=float2(output.get_width(),output.get_height()),uv=(float2(q)+.5)/size;float3 center=sampleImage(input,uv),result=0;float total=0,s=max(.5,p.x);int radius=min(10,int(ceil(s*2)));
    for(int i=-radius;i<=radius;i++){float3 c=sampleImage(input,uv+float2(p.y,p.z)*float(i)/size);float w=exp(-float(i*i)/(2*s*s)-distance_squared(srgb(c),srgb(center))/.02);result+=w*c;total+=w;}
    output.write(half4(half3(result/max(total,1e-6)),1),q);
}
kernel void ve_highlights(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant float4 &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 size=float2(output.get_width(),output.get_height()),ratio=float2(input.get_width(),input.get_height())/size;
    float3 sum=0;float n=0;uint sx=max(1u,uint(ceil(ratio.x))),sy=max(1u,uint(ceil(ratio.y)));
    // Threshold individual source samples before the area average: tiny moving
    // practicals must not disappear between quarter-resolution sample centers.
    for(uint y=0;y<sy;y++)for(uint x=0;x<sx;x++) {
        float2 uv=(float2(q)+(float2(x,y)+.5)/float2(sx,sy))/size;
        // Integral reductions land exactly at source texel centers. Keep
        // bilinear sampling for odd dimensions and non-integral scales.
        bool integral=all(ratio==floor(ratio));
        float3 c=integral ? float3(input.read(q*uint2(sx,sy)+uint2(x,y)).rgb) : sampleImage(input,uv);
        sum+=c*smoothstep(p.x-p.y,p.x+p.y,luma(c));n++;
    }
    output.write(half4(half3(sum/max(n,1.0)),1),q);
}
kernel void ve_guidedStats(texture2d<half,access::sample> guide [[texture(0)]],texture2d<half,access::sample> mask [[texture(1)]],texture2d<half,access::write> output [[texture(2)]],constant uint &radius [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 size=float2(output.get_width(),output.get_height());float4 sum=0;float n=0;int r=int(min(radius,6u));
    for(int y=-r;y<=r;y++)for(int x=-r;x<=r;x++){float2 uv=(float2(q)+float2(x,y)+.5)/size;float i=srgb(float3(luma(sampleImage(guide,uv)))).x,p=float(mask.sample(linearSampler,uv).r);sum+=float4(i,p,i*i,i*p);n++;}
    sum/=n;float a=(sum.w-sum.x*sum.y)/(max(0.0,sum.z-sum.x*sum.x)+.001),b=sum.y-a*sum.x;output.write(half4(a,b,0,1),q);
}
kernel void ve_guidedApply(texture2d<half,access::sample> guide [[texture(0)]],texture2d<half,access::sample> coefficients [[texture(1)]],texture2d<half,access::write> output [[texture(2)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height());float2 ab=float2(coefficients.sample(linearSampler,uv).rg);float a=clamp(ab.x*srgb(float3(luma(sampleImage(guide,uv)))).x+ab.y,0.0,1.0);output.write(half4(a,a,a,1),q);
}
kernel void ve_personCoverage(texture2d<half,access::read> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant float2 &clip [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float a=smoothstep(clip.x,clip.y,float(input.read(q).r));
    output.write(half4(a,a,a,1),q);
}
kernel void ve_keyAlpha(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::sample> screen [[texture(1)]],texture2d<half,access::sample> dilated [[texture(2)]],texture2d<half,access::write> output [[texture(3)]],texture2d<half,access::sample> eroded [[texture(4)]],constant EffectUniforms &u [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height());float3 c=sampleImage(input,uv),s=(u.flags&2)?sampleImage(screen,uv):u.p[0].xyz;
    bool blue=u.p[1].x>1.5||(u.p[1].x<.5&&s.b>s.g);float key=blue?c.b:c.g,other=blue?c.g:c.b,sk=blue?s.b:s.g,so=blue?s.g:s.b;
    float balance=u.p[4].x;float d=key-(abs(balance-.5)<.0001?max(c.r,other):balance*c.r+(1-balance)*other),ds=sk-(abs(balance-.5)<.0001?max(s.r,so):balance*s.r+(1-balance)*so);
    float a=1-clamp(u.p[3].x*d/max(ds,.0001),0.0,1.0);a=clamp((a-u.p[5].x)/max(.0001,u.p[6].x-u.p[5].x),0.0,1.0);
    if((u.flags&1) && u.p[11].x>.5) {
        // Preserve the half-float rounding of the former intermediate matte.
        a=float(half(a));
        if(float(dilated.sample(linearSampler,uv).r)<.005)a=0;
        if(float(eroded.sample(linearSampler,uv).r)>.995&&a>.2)a=1;
    }
    output.write(half4(a,a,a,1),q);
}
kernel void ve_morphology(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant float4 &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 size=float2(output.get_width(),output.get_height()),uv=(float2(q)+.5)/size;float radius=min(64.0,abs(p.x));
    float a=float(input.sample(linearSampler,uv).r);int r=int(floor(radius));
    for(int i=-r;i<=r;i++){float b=float(input.sample(linearSampler,uv+float2(p.y,p.z)*float(i)/size).r);a=p.x>=0?max(a,b):min(a,b);}
    for(int sign=-1;sign<=1;sign+=2){float b=float(input.sample(linearSampler,uv+float2(p.y,p.z)*radius*float(sign)/size).r);a=p.x>=0?max(a,b):min(a,b);}
    output.write(half4(a,a,a,1),q);
}
// Background-only local statistics for edge decontamination and two-layer
// dolly fill. RGB is weighted, alpha stores the known-background coverage.
kernel void ve_bgWeight(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::sample> mask [[texture(1)]],texture2d<half,access::write> output [[texture(2)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height());float weight=1-float(mask.sample(linearSampler,uv).r);
    output.write(half4(half3(sampleImage(input,uv)*weight),half(weight)),q);
}
kernel void ve_bgNormalize(texture2d<half,access::sample> weighted [[texture(0)]],texture2d<half,access::sample> fallback [[texture(1)]],texture2d<half,access::write> output [[texture(2)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height());float4 local=float4(weighted.sample(linearSampler,uv));
    float3 estimate=sampleImage(fallback,uv);if(local.a>.001)estimate=local.rgb/local.a;
    output.write(half4(half3(estimate),1),q);
}
kernel void ve_personHint(texture2d<half,access::sample> alpha [[texture(0)]],texture2d<half,access::sample> dilated [[texture(1)]],texture2d<half,access::sample> eroded [[texture(2)]],texture2d<half,access::write> output [[texture(3)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height());float a=float(alpha.sample(linearSampler,uv).r);
    if(float(dilated.sample(linearSampler,uv).r)<.005)a=0;
    if(float(eroded.sample(linearSampler,uv).r)>.995&&a>.2)a=1;
    output.write(half4(a,a,a,1),q);
}
kernel void ve_reduce(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 size=float2(output.get_width(),output.get_height()),ratio=float2(input.get_width(),input.get_height())/size;
    uint2 count=uint2(max(float2(1),ceil(ratio)));float4 total=0;
    if(all(ratio==floor(ratio)) && all(count%2==0)) {
        // One bilinear fetch is the exact 2×2 linear-light area average.
        // Pairing four such fetches gives the same integral 4×4 reduction.
        for(uint y=0;y<count.y;y+=2)for(uint x=0;x<count.x;x+=2)total+=float4(input.sample(linearSampler,(float2(q)+(float2(x,y)+1)/float2(count))/size));
        total*=4;
    } else {
        for(uint y=0;y<count.y;y++)for(uint x=0;x<count.x;x++)total+=float4(input.sample(linearSampler,(float2(q)+(float2(x,y)+.5)/float2(count))/size));
    }
    output.write(half4(total/float(count.x*count.y)),q);
}

// Original border-median detector. No full frame readback, and no inference
// state: the same image and settings always choose the same screen reference.
kernel void ve_screenReference(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant EffectUniforms &u [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(any(q!=uint2(0)))return;
    float3 samples[64];uint greens=0,blues=0;
    for(uint i=0;i<16;i++) {
        float t=(float(i)+.5)/16;
        const float2 locations[]={float2(t,.02),float2(t,.98),float2(.02,t),float2(.98,t)};
        for(uint edge=0;edge<4;edge++) {
            float3 c=sampleImage(input,locations[edge]);samples[i*4+edge]=c;
            greens+=c.g-max(c.r,c.b)>.02;blues+=c.b-max(c.r,c.g)>.02;
        }
    }
    bool blue=u.p[1].x>1.5||(u.p[1].x<.5&&blues>greens);uint n=0;float3 values[64];
    for(uint i=0;i<64;i++){float3 c=samples[i];if((blue?c.b-max(c.r,c.g):c.g-max(c.r,c.b))>.02)values[n++]=c;}
    float3 color=u.p[0].xyz;
    if(n>=4) {
        for(uint channel=0;channel<3;channel++) {
            for(uint i=1;i<n;i++){float value=values[i][channel];uint j=i;while(j>0&&values[j-1][channel]>value){values[j][channel]=values[j-1][channel];j--;}values[j][channel]=value;}
            color[channel]=values[n/2][channel];
        }
    }
    output.write(half4(half3(color),1),uint2(0));
}
kernel void ve_subjectWeight(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::sample> mask [[texture(1)]],texture2d<half,access::write> output [[texture(2)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height());float a=smoothstep(.5,.95,float(mask.sample(linearSampler,uv).r));
    output.write(half4(half3(sampleImage(input,uv)*a),half(a)),q);
}

kernel void ve_grainNoise(texture2d<half,access::write> output [[texture(0)]],constant uint &frame [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float base=random01(uint3(q,frame+13))*2-1;
    float3 other=float3(random01(uint3(q,frame+29)),random01(uint3(q,frame+59)),random01(uint3(q,frame+101)))*2-1;
    output.write(half4(half3(base*.7+other*.3),half(base)),q);
}

// Temporal segmentation runs only at the small Vision mask resolution. The
// history's second channel stores source luma, not the composited background.
kernel void ve_maskSceneCut(texture2d<half,access::read> guide [[texture(0)]],texture2d<half,access::read> previous [[texture(1)]],texture2d<half,access::write> cut [[texture(2)]],constant float4 &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(any(q!=uint2(0)))return;
    float difference=0;
    if(p.y<0.5)for(uint y=0;y<18;y++)for(uint x=0;x<32;x++) {
        uint2 at=min(uint2((float(x)+0.5)*guide.get_width()/32,(float(y)+0.5)*guide.get_height()/18),uint2(guide.get_width()-1,guide.get_height()-1));
        float l=dot(float3(guide.read(at).rgb),float3(0.2126,0.7152,0.0722));
        difference+=abs(l-float(previous.read(at).g));
    }
    cut.write(half4(p.y>=0.5 || difference/576>p.w ? 1 : 0),uint2(0));
}
kernel void ve_maskTemporal(texture2d<half,access::read> mask [[texture(0)]],texture2d<half,access::read> guide [[texture(1)]],texture2d<half,access::read> previous [[texture(2)]],texture2d<half,access::write> state [[texture(3)]],texture2d<half,access::write> output [[texture(4)]],texture2d<half,access::read> cut [[texture(5)]],constant float4 &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float a=float(mask.read(q).r),l=dot(float3(guide.read(q).rgb),float3(0.2126,0.7152,0.0722));
    if(cut.read(uint2(0)).r<0.5h) {
        float2 old=float2(previous.read(q).rg);
        // Follow moving edges immediately; smooth uncertainty on static edges.
        // Luma alone cannot detect a moving person against a similarly lit
        // wall. Preserve only small confidence fluctuations, never a displaced
        // silhouette, when motion gating is enabled.
        if(abs(l-old.y)<p.z && (!isfinite(p.z) || abs(a-old.x)<0.15))a=mix(old.x,a,p.x);
    }
    state.write(half4(half(a),half(l),0,1),q);
    output.write(half4(half(a)),q);
}

// Finite-window matte history. Quarter-resolution perceptual guides average
// an area before encoding luma, retaining dark-scene changes without aliasing
// a single sensor-noise pixel into the scene-cut and motion decisions.
kernel void ve_isolationAlpha(texture2d<half,access::read> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant EffectUniforms &u [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float3 h=hsv(srgb(float3(input.read(q).rgb))),target=hsv(srgb(u.p[1].xyz));
    float r=u.p[2].x/360,soft=max(.001,u.p[3].x*.1);
    float weight=(1-smoothstep(r,r+soft,hueDistance(h.x,target.x)))*smoothstep(.08,.2,h.y);
    output.write(half4(half(weight)),q);
}
kernel void ve_matteGuide(texture2d<half,access::read> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float sum=0;uint count=0;
    for(uint y=q.y*4;y<min((q.y+1)*4,input.get_height());y++)
        for(uint x=q.x*4;x<min((q.x+1)*4,input.get_width());x++) {sum+=luma(float3(input.read(uint2(x,y)).rgb));count++;}
    output.write(half4(half(srgb(float3(clamp(sum/max(1u,count),0.0,1.0))).x)),q);
}
kernel void ve_matteCuts(array<texture2d<half,access::sample>,8> guides [[texture(8)]],texture2d<half,access::write> output [[texture(17)]],constant float4 &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.y||q.x>=8)return;
    // 0: fresh analysis; 1: recorded decisions only; 2: current frame was
    // skipped by live preview, so test just its new boundary.
    if((p.w>.5 && (p.w<1.5 || q.x>0)) || q.x+1>=uint(p.y)) {output.write(half4(0),q);return;}
    float difference=0;uint a[16]={0},b[16]={0};
    for(uint y=0;y<18;y++)for(uint x=0;x<32;x++) {
        float2 uv=(float2(x,y)+.5)/float2(32,18);
        float current=float(guides[q.x].sample(linearSampler,uv).r),previous=float(guides[q.x+1].sample(linearSampler,uv).r);
        difference+=abs(current-previous);a[min(15u,uint(current*16))]++;b[min(15u,uint(previous*16))]++;
    }
    float histogram=0;for(uint i=0;i<16;i++)histogram+=abs(float(a[i])-float(b[i]));
    difference/=576;histogram/=1152;
    // Large structural changes, or substantial distribution changes with a
    // smaller mean change. No CPU readback and no evolving detector state.
    output.write(half4(difference>.20 || (difference>.08 && histogram>.30) ? 1 : 0),q);
}
kernel void ve_matteWindow(array<texture2d<half,access::sample>,8> mattes [[texture(0)]],array<texture2d<half,access::sample>,8> guides [[texture(8)]],texture2d<half,access::read> cuts [[texture(16)]],texture2d<half,access::write> output [[texture(17)]],constant float4 &p [[buffer(0)]],uint2 q [[thread_position_in_grid]]) {
    if(q.x>=output.get_width()||q.y>=output.get_height())return;
    float2 uv=(float2(q)+.5)/float2(output.get_width(),output.get_height());
    float sum=0,remaining=1;uint count=uint(p.y);
    for(uint i=0;i+1<count;i++) {
        float prior=cuts.read(uint2(i,0)).r>.5h ? 0 : p.x;
        if(p.z>.5) {
            float motion=abs(float(guides[i].sample(linearSampler,uv).r)-float(guides[i+1].sample(linearSampler,uv).r));
            prior*=1-smoothstep(.01,.02,motion);
        }
        float value=mattes[i].get_width()==output.get_width() && mattes[i].get_height()==output.get_height() ? float(mattes[i].read(q).r) : float(mattes[i].sample(linearSampler,uv).r);
        sum+=remaining*(1-prior)*value;remaining*=prior;
        if(remaining==0)break;
    }
    float oldest=mattes[count-1].get_width()==output.get_width() && mattes[count-1].get_height()==output.get_height() ? float(mattes[count-1].read(q).r) : float(mattes[count-1].sample(linearSampler,uv).r);
    sum+=remaining*oldest;
    output.write(half4(half(clamp(sum,0.0,1.0))),q);
}

// Night fix: linear-light source fusion; no neural model. Guides and residuals
// use a perceptual 709 encoding, while actual observations are averaged linearly.
constant sampler nf_sampler(coord::normalized,address::clamp_to_edge,filter::linear);
float3 nf_encode(float3 x) {x=max(x,0.0);return select(1.099*pow(x,float3(0.45))-0.099,4.5*x,x<0.018);}
float3 nf_decode(float3 x) {x=max(x,0.0);return select(pow((x+0.099)/1.099,float3(1.0/0.45)),x/4.5,x<0.081);}
float nf_y(float3 x) {return dot(x,float3(0.2126,0.7152,0.0722));}
kernel void nf_guide(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width() || p.y>=output.get_height())return;
    float2 uv=(float2(p)+0.5)/float2(output.get_width(),output.get_height());float y=0;
    for(int j=-1;j<=1;j++)for(int i=-1;i<=1;i++) {
        float2 at=uv+float2(i,j)*0.65/float2(output.get_width(),output.get_height());
        y+=nf_y(float3(input.sample(nf_sampler,at).rgb))/9.0;
    }
    output.write(half4(half3(sqrt(clamp(y,0.0,1.0))),1),p);
}
kernel void nf_seed(texture2d<half,access::read> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width() || p.y>=output.get_height())return;output.write(half4(half3(nf_decode(float3(input.read(p).rgb))),1),p);
}
float3 nf_smooth(texture2d<half,access::sample> image,float2 uv) {
    float2 delta=1.2/float2(image.get_width(),image.get_height());float3 sum=0;
    for(int j=-1;j<=1;j++)for(int i=-1;i<=1;i++)sum+=float3(image.sample(nf_sampler,uv+float2(i,j)*delta).rgb)/9.0;
    return sum;
}
kernel void nf_fuse(texture2d<half,access::sample> current [[texture(0)]],texture2d<half,access::sample> other [[texture(1)]],texture2d<float,access::sample> forward [[texture(2)]],texture2d<float,access::sample> backward [[texture(3)]],texture2d<half,access::read_write> accum [[texture(4)]],constant float4 &v [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=accum.get_width() || p.y>=accum.get_height())return;
    float2 uv=(float2(p)+0.5)/float2(accum.get_width(),accum.get_height()),size=v.yz;
    float2 f=forward.sample(nf_sampler,uv).rg,at=uv+f/size;
    if(any(at<1.0/size) || any(at>1.0-2.0/size) || !all(isfinite(f)))return;
    float2 b=backward.sample(nf_sampler,at).rg;float agreement=length(f+b);
    if(!isfinite(agreement) || agreement>3.0)return;
    float3 difference=nf_smooth(current,uv)-nf_smooth(other,at);
    float weight=exp(-agreement*agreement/(0.8*0.8))*exp(-dot(difference,difference)/(3.0*pow(6.0/255.0*1.5,2.0)))*exp(-0.5*pow(v.x/3.0,2.0));
    float4 sum=float4(accum.read(p));sum+=float4(nf_decode(float3(other.sample(nf_sampler,at).rgb))*weight,weight);accum.write(half4(sum),p);
}
// Reversible square-root packing protects sub-code-value shadow detail in the
// Main10 cache. The adjustment stage unpacks it before doing any restoration.
kernel void nf_finish(texture2d<half,access::read> sum [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant float4 &v [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width() || p.y>=output.get_height())return;float4 a=float4(sum.read(p));float3 c=nf_encode(a.rgb/max(1.0,a.a));if(v.x>0)c=sqrt(max(c,0.0));output.write(half4(half3(c),1),p);
}
// Adjustable cleanup follows fusion. Values >100% deliberately soften more
// detail. Brightness is a fixed exposure/shoulder, never a per-frame histogram.
kernel void nf_adjust(texture2d<half,access::sample> raw [[texture(0)]],texture2d<half,access::sample> fused [[texture(1)]],texture2d<half,access::write> output [[texture(2)]],constant float4 &v [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width() || p.y>=output.get_height())return;
    float2 uv=(float2(p)+0.5)/float2(output.get_width(),output.get_height());float amount=v.x;
    float3 t=float3(fused.sample(nf_sampler,uv).rgb);if(v.w>0)t*=t;
    float3 c=mix(float3(raw.sample(nf_sampler,uv).rgb),t,min(1.0,amount));
    float radius=0.85+max(0.0,amount-1.0)*1.3;float2 pixel=radius/float2(output.get_width(),output.get_height());
    float3 mean=0,square=0;
    for(int j=-1;j<=1;j++)for(int i=-1;i<=1;i++) {
        float2 at=uv+float2(i,j)*pixel;
        float3 t=float3(fused.sample(nf_sampler,at).rgb);if(v.w>0)t*=t;
        float3 n=mix(float3(raw.sample(nf_sampler,at).rgb),t,min(1.0,amount));
        mean+=n/9.0;square+=n*n/9.0;
    }
    float3 variance=max(square-mean*mean,1e-8);
    float noise2=pow(6.0/255.0,2.0)/3.0*amount*amount*mix(1.5,0.2,v.z);
    float3 keep=clamp(1.0-noise2/variance,0.0,1.0);
    c=nf_decode(mix(c,mean+keep*(c-mean),min(1.0,amount)));
    float y=max(0.0,nf_y(c)),gain=exp2(v.y);
    // Preserve HDR highlights above reference white instead of folding them
    // below white. SDR's gain matches the comparison's white-preserving curve.
    float scale=y<=1.0 ? gain/(1.0+(gain-1.0)*y) : 1.0;
    output.write(half4(half3(nf_encode(max(c*scale,0.0))),1),p);
}
// Separable luminance-guided chroma cleanup. Luma is kept unchanged so broad
// color blotches can be reduced without blurring word/eye edges equally.
kernel void nf_chroma(texture2d<half,access::sample> input [[texture(0)]],texture2d<half,access::write> output [[texture(1)]],constant float4 &v [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width() || p.y>=output.get_height())return;
    float2 uv=(float2(p)+0.5)/float2(output.get_width(),output.get_height());float3 c=float3(input.sample(nf_sampler,uv).rgb);float y=nf_y(c);
    float2 chroma=0;float total=0;int radius=int(clamp(10.0*v.x,1.0,30.0));
    for(int k=-radius;k<=radius;k++) {
        float2 at=uv+float(k)*v.yz/float2(output.get_width(),output.get_height());float3 n=float3(input.sample(nf_sampler,at).rgb);float ny=nf_y(n);
        float weight=exp(-pow(ny-y,2.0)/(0.0012*max(1.0,v.x)))*exp(-0.5*pow(float(k)/max(1.0,float(radius)*0.65),2.0));
        chroma+=float2(n.r-ny,n.b-ny)*weight;total+=weight;
    }
    float2 rb=mix(float2(c.r-y,c.b-y),chroma/max(total,1e-6),min(0.98,0.85*v.x));
    float3 result=float3(y+rb.x,0,y+rb.y);result.g=(y-0.2126*result.r-0.0722*result.b)/0.7152;
    output.write(half4(half3(max(0.0,result)),1),p);
}
kernel void nf_mix(texture2d<half,access::read> raw [[texture(0)]],texture2d<half,access::read> encoded [[texture(1)]],texture2d<half,access::write> output [[texture(2)]],constant float4 &v [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width() || p.y>=output.get_height())return;
    output.write(half4(half3(nf_encode(mix(nf_decode(float3(raw.read(p).rgb)),nf_decode(float3(encoded.read(p).rgb)),v.x))),1),p);
}


// Display-space focus aid. Require both a luminance edge and local high-frequency
// detail so a broad out-of-focus transition does not light up like a sharp edge.
static float recorderSharpEdge(texture2d<float, access::read> picture, uint2 p, uint2 limit) {
    uint2 left = uint2(max(int(p.x) - 1, 0), p.y);
    uint2 top = uint2(p.x, max(int(p.y) - 1, 0));
    float l = luma(picture.read(left).rgb), r = luma(picture.read(min(p + uint2(1, 0), limit)).rgb);
    float t = luma(picture.read(top).rgb), b = luma(picture.read(min(p + uint2(0, 1), limit)).rgb);
    float center = luma(picture.read(p).rgb);
    float gradient = length(float2(r - l, b - t));
    float detail = max(abs(l + r - 2 * center), abs(t + b - 2 * center));
    return smoothstep(0.065, 0.16, gradient) * smoothstep(0.017, 0.06, detail);
}

kernel void recorderFocusPeaking(texture2d<float, access::read> picture [[texture(0)]],
                                 texture2d<float, access::write> display [[texture(1)]],
                                 constant uint &overlayOnly [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    uint2 limit = uint2(picture.get_width(), picture.get_height()) - 1;
    if (any(p > limit)) return;
    float4 color = picture.read(p);
    // Extend an already sharp contour by one display pixel. Keep the
    // high-frequency test intact so a soft edge does not look in focus.
    float strength = max(recorderSharpEdge(picture, p, limit),
                         0.9 * max(recorderSharpEdge(picture, min(p + uint2(1, 0), limit), limit),
                                   recorderSharpEdge(picture, min(p + uint2(0, 1), limit), limit)));
    float3 red = float3(1, 0.045, 0.025);
    display.write(overlayOnly ? float4(strength * red, strength) : float4(mix(color.rgb, red, strength), color.a), p);
}
