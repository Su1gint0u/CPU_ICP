#include <stdio.h>
#define N 5


int main(void) {
    int x[N];
    unsigned int u[N];
    int out_signed[N];
    unsigned int out_unsigned[N];
    float divisor;
    x[0] = 100;
    x[1] = -50;
    x[2] = 25;
    x[3] = -200;
    x[4] = 7;

    u[0] = 20;
    u[1] = 10;
    u[2] = 100;
    u[3] = 3;
    u[4] = 5;

    divisor = 2.0f;
    for (int i = 0; i < N; i++) {
        float xf = (float)x[i];
        float uf = (float)u[i];

        float y = (xf - uf) / divisor;

        out_signed[i] = (int)y;
        out_unsigned[i] = (unsigned int)y;
        printf("out_signed[%d]: %d, ", i, out_signed[i]);
        printf("out_unsigned[%d]: %u\n", i, out_unsigned[i]);
    }
    return 0;
}
