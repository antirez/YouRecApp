#include "StabilizationMotion.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace {
struct Point { double x, y; };
struct Image {
    int w, h;
    std::vector<float> p;
    float at(int x, int y) const { return p[std::min(std::max(y, 0), h-1)*w + std::min(std::max(x, 0), w-1)]; }
    float sample(double x, double y) const {
        int ix = int(std::floor(x)), iy = int(std::floor(y));
        float a = float(x-ix), b = float(y-iy);
        return (at(ix,iy)*(1-a)+at(ix+1,iy)*a)*(1-b)+(at(ix,iy+1)*(1-a)+at(ix+1,iy+1)*a)*b;
    }
};
std::vector<Image> pyramid(const uint8_t *bytes, int w, int h) {
    std::vector<Image> levels;
    Image base{w,h,std::vector<float>(w*h)};
    for (int i=0;i<w*h;++i) base.p[i]=bytes[i];
    levels.push_back(std::move(base));
    for (int level=1;level<4;++level) {
        const Image &s=levels.back();
        Image d{s.w/2,s.h/2,std::vector<float>((s.w/2)*(s.h/2))};
        for(int y=0;y<d.h;++y) for(int x=0;x<d.w;++x) {
            float sum=0;
            for(int j=-1;j<=1;++j) for(int i=-1;i<=1;++i)
                sum+=s.at(2*x+i,2*y+j)*(i==0?2:1)*(j==0?2:1);
            d.p[y*d.w+x]=sum/16;
        }
        levels.push_back(std::move(d));
    }
    return levels;
}
// Grid-distributed Shi-Tomasi corners stop a textured foreground subject from
// consuming the entire feature budget. Re-detect each pair: no long-track drift.
std::vector<Point> corners(const Image &s) {
    struct Corner { double score; Point p; };
    std::vector<Point> result;
    constexpr int columns=12, rows=8;
    for(int gy=0;gy<rows;++gy) for(int gx=0;gx<columns;++gx) {
        std::vector<Corner> candidates;
        for(int y=std::max(9,gy*s.h/rows);y<std::min(s.h-9,(gy+1)*s.h/rows);y+=3)
            for(int x=std::max(9,gx*s.w/columns);x<std::min(s.w-9,(gx+1)*s.w/columns);x+=3) {
                double xx=0,xy=0,yy=0;
                for(int j=-2;j<=2;++j) for(int i=-2;i<=2;++i) {
                    double dx=(s.at(x+i+1,y+j)-s.at(x+i-1,y+j))*0.5;
                    double dy=(s.at(x+i,y+j+1)-s.at(x+i,y+j-1))*0.5;
                    xx+=dx*dx; xy+=dx*dy; yy+=dy*dy;
                }
                double score=(xx+yy-std::sqrt((xx-yy)*(xx-yy)+4*xy*xy))*0.5;
                if(score>250) candidates.push_back({score,{double(x),double(y)}});
            }
        std::sort(candidates.begin(),candidates.end(),[](auto a,auto b){return a.score>b.score;});
        int count=0;
        Point first{};
        for(auto c:candidates) {
            if(count && std::hypot(c.p.x-first.x,c.p.y-first.y)<9) continue;
            result.push_back(c.p); first=c.p;
            if(++count==2) break;
        }
    }
    return result;
}
// Inverse-compositional pyramidal Lucas-Kanade, with a forward/backward check
// at the call site. A mean offset in each patch tolerates mild exposure changes.
bool track(const std::vector<Image> &a,const std::vector<Image> &b,Point p,Point &q) {
    Point displacement{0,0};
    constexpr int radius=4, count=81;
    for(int l=int(a.size())-1;l>=0;--l) {
        if(l<int(a.size())-1) {displacement.x*=2;displacement.y*=2;}
        const auto &s=a[l], &d=b[l];
        double px=p.x/(1<<l), py=p.y/(1<<l);
        double values[count], dx[count], dy[count], xx=0,xy=0,yy=0;
        int k=0;
        for(int j=-radius;j<=radius;++j) for(int i=-radius;i<=radius;++i,++k) {
            values[k]=s.sample(px+i,py+j);
            dx[k]=(s.sample(px+i+1,py+j)-s.sample(px+i-1,py+j))*0.5;
            dy[k]=(s.sample(px+i,py+j+1)-s.sample(px+i,py+j-1))*0.5;
            xx+=dx[k]*dx[k]; xy+=dx[k]*dy[k]; yy+=dy[k]*dy[k];
        }
        double det=xx*yy-xy*xy;
        if(det<1e-5 || std::min(xx,yy)<5) return false;
        for(int iteration=0;iteration<15;++iteration) {
            double qx=px+displacement.x, qy=py+displacement.y;
            if(qx<2 || qy<2 || qx>=d.w-3 || qy>=d.h-3) return false;
            double differences[count], mean=0;
            k=0;
            for(int j=-radius;j<=radius;++j) for(int i=-radius;i<=radius;++i,++k) {
                differences[k]=values[k]-d.sample(qx+i,qy+j);mean+=differences[k];
            }
            mean/=count;
            double bx=0,by=0;
            for(k=0;k<count;++k) {bx+=dx[k]*(differences[k]-mean);by+=dy[k]*(differences[k]-mean);}
            double ux=(yy*bx-xy*by)/det, uy=(xx*by-xy*bx)/det;
            if(!std::isfinite(ux) || !std::isfinite(uy) || std::hypot(ux,uy)>8) return false;
            displacement.x+=ux;displacement.y+=uy;
            if(ux*ux+uy*uy<0.0004) break;
        }
    }
    q={p.x+displacement.x,p.y+displacement.y};
    if(q.x<5 || q.y<5 || q.x>=a[0].w-5 || q.y>=a[0].h-5) return false;
    double error=0,offset=0;
    for(int j=-3;j<=3;++j) for(int i=-3;i<=3;++i) offset+=a[0].sample(p.x+i,p.y+j)-b[0].sample(q.x+i,q.y+j);
    offset/=49;
    for(int j=-3;j<=3;++j) for(int i=-3;i<=3;++i) error+=std::abs(a[0].sample(p.x+i,p.y+j)-b[0].sample(q.x+i,q.y+j)-offset);
    return error/49<22;
}
struct Match {Point p,q;};
struct Similarity {double a=1,b=0,x=0,y=0;};
Similarity fit(const std::vector<Match> &m,const std::vector<int> &ids) {
    Point p{},q{};
    for(int i:ids){p.x+=m[i].p.x;p.y+=m[i].p.y;q.x+=m[i].q.x;q.y+=m[i].q.y;}
    double n=double(ids.size());p.x/=n;p.y/=n;q.x/=n;q.y/=n;
    double aa=0,bb=0,denom=0;
    for(int i:ids) {
        double x=m[i].p.x-p.x,y=m[i].p.y-p.y,u=m[i].q.x-q.x,v=m[i].q.y-q.y;
        aa+=x*u+y*v;bb+=x*v-y*u;denom+=x*x+y*y;
    }
    if(denom<1) return {};
    double a=aa/denom,b=bb/denom;
    return {a,b,q.x-a*p.x+b*p.y,q.y-b*p.x-a*p.y};
}
double error(const Similarity &s,const Match &m) {
    return std::hypot(s.a*m.p.x-s.b*m.p.y+s.x-m.q.x,s.b*m.p.x+s.a*m.p.y+s.y-m.q.y);
}
}

YRMotion yr_estimate_motion(const uint8_t *previous,const uint8_t *current,int width,int height) {
    YRMotion result{};
    if(!previous || !current || width<64 || height<64) return result;
    auto a=pyramid(previous,width,height),b=pyramid(current,width,height);
    auto points=corners(a[0]);
    std::vector<Match> matches;
    for(auto p:points) {
        Point q,back;
        if(track(a,b,p,q) && track(b,a,q,back) && std::hypot(back.x-p.x,back.y-p.y)<0.9)
            matches.push_back({{p.x-width*0.5,p.y-height*0.5},{q.x-width*0.5,q.y-height*0.5}});
    }
    if(matches.size()<12) return result;
    std::vector<int> best;
    // Background near the edges is usually a better camera-motion reference
    // than a vlogger's moving face in the center. Grid sampling plus this mild
    // spatial prior still permits scenes whose useful texture is central.
    std::vector<double> weights;
    double totalWeight=0,bestWeight=0;
    for(auto m:matches) {
        double weight=(std::abs(m.p.x)>width*0.3 || std::abs(m.p.y)>height*0.35)?2.5:1;
        weights.push_back(weight);totalWeight+=weight;
    }
    uint32_t random=0x783f9a31;
    auto next=[&](){random^=random<<13;random^=random>>17;random^=random<<5;return random;};
    for(int iteration=0;iteration<180;++iteration) {
        int i=next()%matches.size(),j=next()%matches.size();
        if(std::hypot(matches[i].p.x-matches[j].p.x,matches[i].p.y-matches[j].p.y)<width*0.12) continue;
        auto s=fit(matches,{i,j});
        double scale=std::hypot(s.a,s.b);
        if(scale<0.9 || scale>1.1 || std::abs(std::atan2(s.b,s.a))>0.18) continue;
        std::vector<int> inliers;
        double weight=0;
        for(int k=0;k<int(matches.size());++k) if(error(s,matches[k])<1.6) {inliers.push_back(k);weight+=weights[k];}
        if(weight>bestWeight) {best=std::move(inliers);bestWeight=weight;}
    }
    if(best.size()<12 || bestWeight<totalWeight*0.48) return result;
    auto s=fit(matches,best);
    std::vector<int> refined;
    for(int k=0;k<int(matches.size());++k) if(error(s,matches[k])<1.6) refined.push_back(k);
    if(refined.size()<12) return result;
    s=fit(matches,refined);
    double minX=width,maxX=-width,minY=height,maxY=-height;
    for(int i:refined) {minX=std::min(minX,matches[i].p.x);maxX=std::max(maxX,matches[i].p.x);minY=std::min(minY,matches[i].p.y);maxY=std::max(maxY,matches[i].p.y);}
    // Don't stabilize to a small moving object in an otherwise blank frame.
    if(maxX-minX<width*0.35 || maxY-minY<height*0.3) return result;
    double scale=std::hypot(s.a,s.b),angle=std::atan2(s.b,s.a);
    if(scale<0.93 || scale>1.07 || std::abs(angle)>0.14 || std::hypot(s.x/width,s.y/height)>0.16) return result;
    result={s.x,s.y,angle,std::log(scale),double(refined.size())/matches.size(),int(refined.size()),1};
    return result;
}
