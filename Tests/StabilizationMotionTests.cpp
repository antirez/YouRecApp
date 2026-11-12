#include "../YouRec/StabilizationMotion.h"
#include <vector>
#include <random>
#include <cmath>
#include <cstdio>
#include <chrono>
int main(){
 int w=640,h=360;std::mt19937 g(731);std::vector<uint8_t>a(w*h,100),b(w*h);
 for(int n=0;n<600;n++){int x=g()%w,y=g()%h,r=2+g()%14,c=30+g()%200;for(int j=-r;j<=r;j++)for(int i=-r;i<=r;i++)if(x+i>=0&&x+i<w&&y+j>=0&&y+j<h)a[(y+j)*w+x+i]=c;}
 auto sample=[&](double x,double y){int ix=floor(x),iy=floor(y); if(ix<0||iy<0||ix>=w-1||iy>=h-1)return 100.0;double u=x-ix,v=y-iy;return(a[iy*w+ix]*(1-u)+a[iy*w+ix+1]*u)*(1-v)+(a[(iy+1)*w+ix]*(1-u)+a[(iy+1)*w+ix+1]*u)*v;};
 for(auto angle:{0.,0.015,-0.025}){
 double dx=6,dy=-4,scale=1.005;
 for(int y=0;y<h;y++)for(int x=0;x<w;x++){double cx=x-w/2-dx,cy=y-h/2-dy;b[y*w+x]=sample((cos(angle)*cx+sin(angle)*cy)/scale+w/2,(-sin(angle)*cx+cos(angle)*cy)/scale+h/2);}
 auto t=std::chrono::steady_clock::now();auto m=yr_estimate_motion(a.data(),b.data(),w,h);double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t).count();
 printf("valid %d x %.3f y %.3f angle %.5f scale %.5f inliers %d ratio %.3f ms %.1f\n",m.valid,m.x,m.y,m.angle,exp(m.logScale),m.inliers,m.inlierRatio,ms);
 if(!m.valid||fabs(m.x-dx)>0.3||fabs(m.y-dy)>0.3||fabs(m.angle-angle)>0.002) return 1;
 }
 // A large, independently moving foreground must not become the camera path.
 for(int y=0;y<h;y++)for(int x=0;x<w;x++) b[y*w+x]=sample(x-6,y+4);
 for(int y=85;y<285;y++)for(int x=175;x<465;x++) b[y*w+x]=sample(x+9,y-5);
 auto foreground=yr_estimate_motion(a.data(),b.data(),w,h);
 printf("foreground: valid %d x %.3f y %.3f inliers %d\n",foreground.valid,foreground.x,foreground.y,foreground.inliers);
 if(!foreground.valid || fabs(foreground.x-6)>.5 || fabs(foreground.y+4)>.5) return 2;
 std::vector<uint8_t> blank(w*h,128);
 if(yr_estimate_motion(blank.data(),blank.data(),w,h).valid) return 3;
 std::vector<uint8_t> cut=a;for(auto &v:cut)v=255-v;
 if(yr_estimate_motion(a.data(),cut.data(),w,h).valid) return 4;
 puts("PASS: subpixel translation/rotation/zoom tracking, moving foreground rejection, textureless frames and scene cuts");
 return 0;
}
