static volatile int local_value = 7;

int rel10_read_a(void)
{
    return local_value;
}
