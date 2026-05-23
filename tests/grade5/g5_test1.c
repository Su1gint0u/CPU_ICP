#include <math.h>
#include <stdio.h>

struct Coordinate {
    double x;
    double y;
} typedef Coordinate;

int main() {
    Coordinate from = { .x = -50, .y = 25 };
    Coordinate to = { .x = 13, .y = -5 };

    double x = to.x - from.x;
    double y = to.y - from.y;
    double dist = sqrt(x*x + y*y);

    printf("Distance: %f\n", dist);

    return 0;
}
